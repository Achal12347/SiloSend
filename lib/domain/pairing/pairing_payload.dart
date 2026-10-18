import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/transport_contract.dart';

/// Data payload exchanged out-of-band via NFC tap or QR code scan.
///
/// Communicates direct connection parameters (LAN IP/port, BLE UUID/MAC, supported transports),
/// an ephemeral correlation token to initiate transport connections, and optional
/// cryptographic identity commitments for out-of-band mutual authentication.
class PairingPayload {
  static const int maxDisplayNameBytes = 32;
  static const String ndefMimeType = 'application/vnd.vayu.pairing';
  static const String uriScheme = 'vayu';
  static const String legacyUriScheme = 'silosend';
  static const String uriHost = 'pair';
  static const String nfcCommitmentDomainTag = 'SiloSend-NFC-Commitment-v1:';

  final int protocolVersion;
  final String deviceIdHex;
  final String displayName;
  final Set<TransportType> supportedTransports;
  final String? lanAddress;
  final int? lanPort;
  final String? bleServiceUuid;
  final String? bleDeviceAddress;
  final String pairingToken;
  final String? ed25519PubKeyHex;
  final String? nfcCommitmentHex;

  /// Phone-hosted Wi-Fi the joiner should connect to when the two phones share
  /// no network (Android LocalOnlyHotspot). Both null otherwise.
  final String? wifiSsid;
  final String? wifiPassphrase;

  /// True when [wifiSsid] is a Wi-Fi Direct group rather than a hotspot. Such
  /// a group also takes plain Wi-Fi clients, so builds that ignore this flag
  /// still join it the hotspot way.
  final bool wifiDirect;

  /// The showing phone's address on the shared router, tried when joining
  /// its Wi-Fi Direct group fails ([lanAddress] is then the group address).
  final String? fallbackLanAddress;

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
    this.ed25519PubKeyHex,
    this.nfcCommitmentHex,
    this.wifiSsid,
    this.wifiPassphrase,
    this.wifiDirect = false,
    this.fallbackLanAddress,
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
    if (ed25519PubKeyHex != null) {
      if (ed25519PubKeyHex!.length != 64 ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(ed25519PubKeyHex!)) {
        throw ArgumentError.value(
          ed25519PubKeyHex,
          'ed25519PubKeyHex',
          'Ed25519 public key must be a 64-character hexadecimal string',
        );
      }
    }
    if (nfcCommitmentHex != null) {
      if (nfcCommitmentHex!.length != 64 ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(nfcCommitmentHex!)) {
        throw ArgumentError.value(
          nfcCommitmentHex,
          'nfcCommitmentHex',
          'NFC commitment must be a 64-character hexadecimal string',
        );
      }
      if (ed25519PubKeyHex == null) {
        throw ArgumentError(
          'ed25519PubKeyHex must be provided when nfcCommitmentHex is specified',
        );
      }
      final computed = computeCommitmentHex(
        pubKeyHex: ed25519PubKeyHex!,
        pairingTokenHex: pairingToken,
      );
      if (computed.toLowerCase() != nfcCommitmentHex!.toLowerCase()) {
        throw ArgumentError(
          'NFC commitment mismatch: computed $computed, got $nfcCommitmentHex',
        );
      }
    }
  }

  /// Sanitizes display name: strips control characters, clamps to max 32 UTF-8 bytes.
  static String sanitizeDisplayName(String name) {
    final stripped = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    final effective = stripped.isEmpty ? 'Vayu-Device' : stripped;
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

  /// Computes canonical 32-byte (64 hex characters) SHA-256 NFC commitment:
  /// SHA-256("SiloSend-NFC-Commitment-v1:" || Ed25519PublicKey || pairingSecret)
  static String computeCommitmentHex({
    String? pubKeyHex,
    String? pairingTokenHex,
    Uint8List? ed25519PubKey,
    Uint8List? pairingSecret,
  }) {
    final pubKeyBytes =
        ed25519PubKey ??
        (pubKeyHex != null
            ? _hexToBytes(pubKeyHex)
            : throw ArgumentError('pubKeyHex or ed25519PubKey required'));
    final secretBytes =
        pairingSecret ??
        (pairingTokenHex != null
            ? _hexToBytes(pairingTokenHex)
            : throw ArgumentError('pairingTokenHex or pairingSecret required'));
    final domainTag = utf8.encode(nfcCommitmentDomainTag);
    final buffer = Uint8List(
      domainTag.length + pubKeyBytes.length + secretBytes.length,
    );
    buffer.setRange(0, domainTag.length, domainTag);
    buffer.setRange(
      domainTag.length,
      domainTag.length + pubKeyBytes.length,
      pubKeyBytes,
    );
    buffer.setRange(
      domainTag.length + pubKeyBytes.length,
      buffer.length,
      secretBytes,
    );
    final digest = crypto.sha256.convert(buffer);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Factory creating a pairing payload with automatically computed NFC commitment.
  factory PairingPayload.createWithNfcCommitment({
    int protocolVersion = AppConstants.protocolVersion,
    required String deviceIdHex,
    required String displayName,
    Set<TransportType> supportedTransports = const {TransportType.lan},
    String? lanAddress,
    int? lanPort,
    String? bleServiceUuid,
    String? bleDeviceAddress,
    String? pairingToken,
    String? ed25519PubKeyHex,
    Uint8List? ed25519PubKey,
    Uint8List? pairingSecret,
    int? timestamp,
  }) {
    final effectivePubKeyHex =
        ed25519PubKeyHex ??
        (ed25519PubKey != null
            ? ed25519PubKey
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join()
            : throw ArgumentError(
                'ed25519PubKeyHex or ed25519PubKey required',
              ));
    final effectiveTokenHex = pairingSecret != null
        ? pairingSecret.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
        : (pairingToken ??
              (throw ArgumentError('pairingToken or pairingSecret required')));

    final commitment = computeCommitmentHex(
      pubKeyHex: effectivePubKeyHex,
      pairingTokenHex: effectiveTokenHex,
    );
    return PairingPayload(
      protocolVersion: protocolVersion,
      deviceIdHex: deviceIdHex,
      displayName: displayName,
      supportedTransports: supportedTransports,
      lanAddress: lanAddress,
      lanPort: lanPort,
      bleServiceUuid: bleServiceUuid,
      bleDeviceAddress: bleDeviceAddress,
      pairingToken: effectiveTokenHex,
      ed25519PubKeyHex: effectivePubKeyHex.toLowerCase(),
      nfcCommitmentHex: commitment.toLowerCase(),
      timestamp: timestamp,
    );
  }

  Uint8List? get ed25519PubKeyBytes =>
      ed25519PubKeyHex != null ? _hexToBytes(ed25519PubKeyHex!) : null;

  Uint8List? get nfcCommitmentBytes =>
      nfcCommitmentHex != null ? _hexToBytes(nfcCommitmentHex!) : null;

  Uint8List get pairingSecretBytes => _hexToBytes(pairingToken);

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
    if (ed25519PubKeyHex != null) 'pubKey': ed25519PubKeyHex,
    if (nfcCommitmentHex != null) 'nfcCommitment': nfcCommitmentHex,
    if (wifiSsid != null) 'wifiSsid': wifiSsid,
    if (wifiPassphrase != null) 'wifiPassphrase': wifiPassphrase,
    if (wifiDirect) 'wifiDirect': true,
    if (fallbackLanAddress != null) 'altLan': fallbackLanAddress,
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

    final displayName = json['displayName'] as String? ?? 'Vayu-Device';
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

    final pubKey = json['pubKey'] as String?;
    final nfcCommitment = json['nfcCommitment'] as String?;

    try {
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
        ed25519PubKeyHex: pubKey,
        nfcCommitmentHex: nfcCommitment,
        wifiSsid: json['wifiSsid'] as String?,
        wifiPassphrase: json['wifiPassphrase'] as String?,
        wifiDirect: json['wifiDirect'] == true,
        fallbackLanAddress: json['altLan'] as String?,
        timestamp:
            json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      );
    } on ArgumentError catch (e) {
      throw FormatException('Invalid pairing payload parameter: ${e.message}');
    }
  }

  /// Serializes to a standard `vayu://pair?...` URI (for QR codes and NFC URI records).
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
    if (ed25519PubKeyHex != null) {
      queryParams['pk'] = ed25519PubKeyHex!;
    }
    if (nfcCommitmentHex != null) {
      queryParams['nfc'] = nfcCommitmentHex!;
    }
    if (wifiSsid != null) {
      queryParams['ssid'] = wifiSsid!;
    }
    if (wifiPassphrase != null) {
      queryParams['psk'] = wifiPassphrase!;
    }
    if (wifiDirect) {
      queryParams['p2p'] = '1';
    }
    if (fallbackLanAddress != null) {
      queryParams['alt'] = fallbackLanAddress!;
    }

    return Uri(scheme: uriScheme, host: uriHost, queryParameters: queryParams);
  }

  /// Deserializes from a `vayu://pair?...` (or legacy `silosend://pair?...`) URI.
  factory PairingPayload.fromUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != uriScheme && scheme != legacyUriScheme) {
      throw FormatException(
        'Invalid URI scheme: ${uri.scheme}, expected $uriScheme or $legacyUriScheme',
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
    final displayName = params['name'] ?? 'Vayu-Device';
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

    final pubKey = params['pk'];
    final nfcCommitment = params['nfc'];

    try {
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
        ed25519PubKeyHex: pubKey,
        nfcCommitmentHex: nfcCommitment,
        wifiSsid: params['ssid'],
        wifiPassphrase: params['psk'],
        wifiDirect: params['p2p'] == '1',
        fallbackLanAddress: params['alt'],
        timestamp: timestamp,
      );
    } on ArgumentError catch (e) {
      throw FormatException('Invalid pairing URI parameter: ${e.message}');
    }
  }

  /// Encodes this pairing payload into a standard NFC Forum NDEF MIME media record
  /// (`application/vnd.vayu.pairing`).
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
    String? ed25519PubKeyHex,
    String? nfcCommitmentHex,
    String? wifiSsid,
    String? wifiPassphrase,
    bool? wifiDirect,
    String? fallbackLanAddress,
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
      ed25519PubKeyHex: ed25519PubKeyHex ?? this.ed25519PubKeyHex,
      nfcCommitmentHex: nfcCommitmentHex ?? this.nfcCommitmentHex,
      wifiSsid: wifiSsid ?? this.wifiSsid,
      wifiPassphrase: wifiPassphrase ?? this.wifiPassphrase,
      wifiDirect: wifiDirect ?? this.wifiDirect,
      fallbackLanAddress: fallbackLanAddress ?? this.fallbackLanAddress,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll(' ', '')
        .toLowerCase();
    if (clean.length % 2 != 0) {
      throw const FormatException('Hex string must have an even length');
    }
    final bytes = Uint8List(clean.length ~/ 2);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
