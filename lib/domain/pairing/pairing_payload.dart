import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:silosend_datasharing_app/core/constants/app_constants.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';

/// Data payload exchanged out-of-band via NFC tap or QR code scan.
///
/// Communicates direct connection parameters (LAN IP/port, BLE UUID/MAC, supported transports)
/// and an ephemeral correlation token to initiate transport connections.
///
/// NOTE: Out-of-band pairing establishes transport connectivity parameters.
/// It is NOT cryptographic authentication. Cryptographic proof of identity,
/// mutual authentication, and end-to-end encrypted session establishment
/// occur independently in the Secure Session layer (Phase 6).
class PairingPayload {
  static const int maxDisplayNameBytes = 32;
  static const String ndefMimeType = 'application/vnd.silosend.pairing';
  static const String uriScheme = 'silosend';
  static const String uriHost = 'pair';

  final int protocolVersion;
  final String deviceIdHex;
  final String displayName;
  final Set<TransportType> supportedTransports;
  final String? lanAddress;
  final int? lanPort;
  final String? bleServiceUuid;
  final String? bleDeviceAddress;
  final String pairingToken;
  final int timestamp;

  PairingPayload({
    this.protocolVersion = AppConstants.protocolVersion,
    required this.deviceIdHex,
    required String displayName,
    this.supportedTransports = const {TransportType.lan},
    this.lanAddress,
    this.lanPort,
    this.bleServiceUuid,
    this.bleDeviceAddress,
    required this.pairingToken,
    int? timestamp,
  }) : displayName = sanitizeDisplayName(displayName),
       timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch {
    if (deviceIdHex.length != 32 ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(deviceIdHex)) {
      throw ArgumentError.value(
        deviceIdHex,
        'deviceIdHex',
        'Device ID must be a 32-character hexadecimal string',
      );
    }
    if (pairingToken.trim().isEmpty) {
      throw ArgumentError.value(
        pairingToken,
        'pairingToken',
        'Pairing token cannot be empty',
      );
    }
    if (lanPort != null && (lanPort! <= 0 || lanPort! > 65535)) {
      throw ArgumentError.value(
        lanPort,
        'lanPort',
        'LAN port must be between 1 and 65535',
      );
    }
  }

  /// Sanitizes display name: strips control characters, clamps to max 32 UTF-8 bytes.
  static String sanitizeDisplayName(String name) {
    final stripped = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    final effective = stripped.isEmpty ? 'SiloSend-Device' : stripped;
    final encoded = utf8.encode(effective);
    if (encoded.length <= maxDisplayNameBytes) {
      return effective;
    }
    final clamped = encoded.sublist(0, maxDisplayNameBytes);
    return utf8.decode(clamped, allowMalformed: true);
  }

  /// Generates a cryptographically random 16-byte (32-character hex) pairing token.
  static String generatePairingToken() {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Map<String, dynamic> toJson() => {
    'version': protocolVersion,
    'deviceId': deviceIdHex,
    'displayName': displayName,
    'transports': supportedTransports.map((t) => t.name).toList(),
    if (lanAddress != null) 'lanAddress': lanAddress,
    if (lanPort != null) 'lanPort': lanPort,
    if (bleServiceUuid != null) 'bleServiceUuid': bleServiceUuid,
    if (bleDeviceAddress != null) 'bleDeviceAddress': bleDeviceAddress,
    'pairingToken': pairingToken,
    'timestamp': timestamp,
  };

  factory PairingPayload.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? AppConstants.protocolVersion;
    final deviceId = json['deviceId'] as String?;
    if (deviceId == null || deviceId.length != 32) {
      throw FormatException(
        'Invalid or missing deviceId in pairing payload: $deviceId',
      );
    }

    final displayName = json['displayName'] as String? ?? 'SiloSend-Device';
    final token = json['pairingToken'] as String?;
    if (token == null || token.trim().isEmpty) {
      throw const FormatException(
        'Missing or empty pairingToken in pairing payload',
      );
    }

    final transportsList = json['transports'] as List<dynamic>? ?? [];
    final transports = transportsList.map((item) {
      final name = item.toString();
      return TransportType.values.firstWhere(
        (t) => t.name == name,
        orElse: () => TransportType.lan,
      );
    }).toSet();

    return PairingPayload(
      protocolVersion: version,
      deviceIdHex: deviceId,
      displayName: displayName,
      supportedTransports: transports.isEmpty
          ? const {TransportType.lan}
          : transports,
      lanAddress: json['lanAddress'] as String?,
      lanPort: json['lanPort'] as int?,
      bleServiceUuid: json['bleServiceUuid'] as String?,
      bleDeviceAddress: json['bleDeviceAddress'] as String?,
      pairingToken: token,
      timestamp:
          json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Serializes to a standard `silosend://pair?...` URI (for QR codes and NFC URI records).
  Uri toUri() {
    final queryParams = <String, String>{
      'v': protocolVersion.toString(),
      'id': deviceIdHex,
      'name': displayName,
      'token': pairingToken,
      'transports': supportedTransports.map((t) => t.name).join(','),
      't': timestamp.toString(),
    };
    if (lanAddress != null && lanPort != null) {
      queryParams['lan'] = '$lanAddress:$lanPort';
    }
    if (bleServiceUuid != null) {
      queryParams['bleUuid'] = bleServiceUuid!;
    }
    if (bleDeviceAddress != null) {
      queryParams['bleMac'] = bleDeviceAddress!;
    }

    return Uri(scheme: uriScheme, host: uriHost, queryParameters: queryParams);
  }

  /// Deserializes from a `silosend://pair?...` URI.
  factory PairingPayload.fromUri(Uri uri) {
    if (uri.scheme.toLowerCase() != uriScheme) {
      throw FormatException(
        'Invalid URI scheme: ${uri.scheme}, expected $uriScheme',
      );
    }
    if (uri.host.toLowerCase() != uriHost) {
      throw FormatException('Invalid URI host: ${uri.host}, expected $uriHost');
    }

    final params = uri.queryParameters;
    final deviceId = params['id'];
    if (deviceId == null || deviceId.length != 32) {
      throw FormatException(
        'Invalid or missing id parameter in URI: $deviceId',
      );
    }

    final token = params['token'];
    if (token == null || token.trim().isEmpty) {
      throw const FormatException('Missing token parameter in URI');
    }

    final version =
        int.tryParse(params['v'] ?? '') ?? AppConstants.protocolVersion;
    final displayName = params['name'] ?? 'SiloSend-Device';
    final timestamp =
        int.tryParse(params['t'] ?? '') ??
        DateTime.now().millisecondsSinceEpoch;

    // Parse transports
    final transportsStr = params['transports'] ?? 'lan';
    final transports = transportsStr.split(',').map((name) {
      return TransportType.values.firstWhere(
        (t) => t.name == name.trim(),
        orElse: () => TransportType.lan,
      );
    }).toSet();

    // Parse LAN endpoint
    String? lanAddress;
    int? lanPort;
    final lanParam = params['lan'];
    if (lanParam != null && lanParam.contains(':')) {
      final parts = lanParam.split(':');
      lanAddress = parts[0];
      lanPort = int.tryParse(parts[1]);
    }

    return PairingPayload(
      protocolVersion: version,
      deviceIdHex: deviceId,
      displayName: displayName,
      supportedTransports: transports,
      lanAddress: lanAddress,
      lanPort: lanPort,
      bleServiceUuid: params['bleUuid'],
      bleDeviceAddress: params['bleMac'],
      pairingToken: token,
      timestamp: timestamp,
    );
  }

  /// Encodes this pairing payload into a standard NFC Forum NDEF MIME media record
  /// (`application/vnd.silosend.pairing`).
  Uint8List toNdefBytes() {
    final payloadBytes = utf8.encode(jsonEncode(toJson()));
    final typeBytes = utf8.encode(ndefMimeType);

    final isShortRecord = payloadBytes.length <= 255;
    // MB=1, ME=1, CF=0, SR=(0 or 1), IL=0, TNF=0x02 (MIME Media)
    final headerByte = 0x80 | 0x40 | (isShortRecord ? 0x10 : 0x00) | 0x02;

    final buffer = BytesBuilder();
    buffer.addByte(headerByte);
    buffer.addByte(typeBytes.length);

    if (isShortRecord) {
      buffer.addByte(payloadBytes.length);
    } else {
      final lenData = ByteData(4)
        ..setUint32(0, payloadBytes.length, Endian.big);
      buffer.add(lenData.buffer.asUint8List());
    }

    buffer.add(typeBytes);
    buffer.add(payloadBytes);
    return buffer.toBytes();
  }

  /// Decodes a [PairingPayload] from raw NDEF bytes or fallback JSON bytes.
  static PairingPayload fromNdefBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('Empty NDEF byte buffer');
    }

    // Direct JSON fallback (if raw payload was transmitted without NDEF header)
    if (bytes[0] == 0x7B) {
      // '{'
      try {
        final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        return PairingPayload.fromJson(map);
      } catch (e) {
        throw FormatException('Failed to parse raw JSON pairing payload: $e');
      }
    }

    if (bytes.length < 3) {
      throw const FormatException('NDEF buffer too short');
    }

    final header = bytes[0];
    final isShortRecord = (header & 0x10) != 0;
    final tnf = header & 0x07;
    final typeLength = bytes[1];

    int offset = 2;
    int payloadLength;

    if (isShortRecord) {
      if (bytes.length < offset + 1) {
        throw const FormatException(
          'NDEF short record missing payload length byte',
        );
      }
      payloadLength = bytes[offset++];
    } else {
      if (bytes.length < offset + 4) {
        throw const FormatException(
          'NDEF record missing 4-byte payload length field',
        );
      }
      final byteData = ByteData.sublistView(bytes, offset, offset + 4);
      payloadLength = byteData.getUint32(0, Endian.big);
      offset += 4;
    }

    if (bytes.length < offset + typeLength + payloadLength) {
      throw FormatException(
        'Incomplete NDEF record: expected ${offset + typeLength + payloadLength} bytes, got ${bytes.length}',
      );
    }

    final typeStr = utf8.decode(bytes.sublist(offset, offset + typeLength));
    offset += typeLength;

    final payloadBytes = bytes.sublist(offset, offset + payloadLength);

    if (tnf == 0x02 && typeStr == ndefMimeType) {
      final jsonStr = utf8.decode(payloadBytes);
      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      return PairingPayload.fromJson(jsonMap);
    } else if (tnf == 0x01 && typeStr == 'U') {
      // NFC Forum Well-Known URI record
      // First byte is URI identifier prefix code (0x00 for raw URI)
      if (payloadBytes.isEmpty) {
        throw const FormatException('Empty URI payload in NDEF record');
      }
      final uriStr = utf8.decode(payloadBytes.sublist(1));
      return PairingPayload.fromUri(Uri.parse(uriStr));
    } else {
      // Best-effort JSON parse
      final jsonStr = utf8.decode(payloadBytes);
      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      return PairingPayload.fromJson(jsonMap);
    }
  }

  PairingPayload copyWith({
    int? protocolVersion,
    String? deviceIdHex,
    String? displayName,
    Set<TransportType>? supportedTransports,
    String? lanAddress,
    int? lanPort,
    String? bleServiceUuid,
    String? bleDeviceAddress,
    String? pairingToken,
    int? timestamp,
  }) {
    return PairingPayload(
      protocolVersion: protocolVersion ?? this.protocolVersion,
      deviceIdHex: deviceIdHex ?? this.deviceIdHex,
      displayName: displayName ?? this.displayName,
      supportedTransports: supportedTransports ?? this.supportedTransports,
      lanAddress: lanAddress ?? this.lanAddress,
      lanPort: lanPort ?? this.lanPort,
      bleServiceUuid: bleServiceUuid ?? this.bleServiceUuid,
      bleDeviceAddress: bleDeviceAddress ?? this.bleDeviceAddress,
      pairingToken: pairingToken ?? this.pairingToken,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
