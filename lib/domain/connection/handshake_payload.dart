import 'dart:convert';
import 'dart:typed_data';

import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/transport_contract.dart';

/// Payload exchanged during transport handshake to negotiate session parameters
/// and verify basic presence and protocol compatibility between peers.
///
/// NOTE: Handshake establishes transport session readiness and presence claim.
/// It is NOT cryptographic authentication. Authentication and secure key exchange
/// occur independently in the Secure Session layer (Phase 6).
class HandshakePayload {
  static const int maxDisplayNameBytes = 32;

  final int protocolVersion;
  final String sessionId;
  final String deviceIdHex;
  final String displayName;
  final String platform;
  final Set<TransportType> supportedTransports;
  final bool accepted;
  final String? rejectionReason;
  final int timestamp;

  /// Optional features the sender understands (see [AppConstants.protocolFeatures]).
  final Set<String> features;

  HandshakePayload({
    this.protocolVersion = AppConstants.protocolVersion,
    required this.sessionId,
    required this.deviceIdHex,
    required String displayName,
    required this.platform,
    this.supportedTransports = const {TransportType.lan},
    this.accepted = true,
    this.rejectionReason,
    int? timestamp,
    this.features = AppConstants.protocolFeatures,
  }) : displayName = sanitizeDisplayName(displayName),
       timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'Session ID cannot be empty',
      );
    }
    if (deviceIdHex.length != 32 ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(deviceIdHex)) {
      throw ArgumentError.value(
        deviceIdHex,
        'deviceIdHex',
        'Device ID must be a 32-character hexadecimal string',
      );
    }
  }

  /// Converts the 32-character hex device ID into a 16-byte raw Uint8List.
  Uint8List get deviceIdBytes {
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(deviceIdHex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// Sanitizes and clamps display names to 32 UTF-8 bytes max, stripping control chars.
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

  Map<String, dynamic> toJson() => {
    'version': protocolVersion,
    'sessionId': sessionId,
    'deviceId': deviceIdHex,
    'displayName': displayName,
    'platform': platform,
    'transports': supportedTransports.map((t) => t.name).toList(),
    'accepted': accepted,
    if (rejectionReason != null) 'rejectionReason': rejectionReason,
    'timestamp': timestamp,
    'features': features.toList(),
  };

  factory HandshakePayload.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? AppConstants.protocolVersion;
    final sessionId = json['sessionId'] as String?;
    if (sessionId == null || sessionId.trim().isEmpty) {
      throw const FormatException(
        'Missing or empty sessionId in handshake payload',
      );
    }

    final deviceId = json['deviceId'] as String?;
    if (deviceId == null || deviceId.length != 32) {
      throw FormatException(
        'Invalid or missing deviceId in handshake payload: $deviceId',
      );
    }

    final displayName = json['displayName'] as String? ?? 'Vayu-Device';
    final platform = json['platform'] as String? ?? 'unknown';

    final transportsList = json['transports'] as List<dynamic>? ?? [];
    final transports = transportsList.map((item) {
      final name = item.toString();
      return TransportType.values.firstWhere(
        (t) => t.name == name,
        orElse: () => TransportType.lan,
      );
    }).toSet();

    final accepted = json['accepted'] as bool? ?? true;
    final rejectionReason = json['rejectionReason'] as String?;
    final timestamp =
        json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    // Absent on older builds: they support no optional features.
    final features = (json['features'] as List<dynamic>? ?? const [])
        .map((f) => f.toString())
        .toSet();

    return HandshakePayload(
      protocolVersion: version,
      sessionId: sessionId,
      deviceIdHex: deviceId,
      displayName: displayName,
      platform: platform,
      supportedTransports: transports.isEmpty
          ? const {TransportType.lan}
          : transports,
      accepted: accepted,
      features: features,
      rejectionReason: rejectionReason,
      timestamp: timestamp,
    );
  }

  Uint8List toBytes() {
    final jsonStr = jsonEncode(toJson());
    return Uint8List.fromList(utf8.encode(jsonStr));
  }

  static HandshakePayload fromBytes(Uint8List bytes) {
    try {
      final jsonStr = utf8.decode(bytes);
      final jsonMap = jsonDecode(jsonStr);
      if (jsonMap is! Map<String, dynamic>) {
        throw const FormatException('Handshake JSON must be an object map');
      }
      return HandshakePayload.fromJson(jsonMap);
    } catch (e) {
      if (e is FormatException) rethrow;
      throw FormatException('Failed to parse HandshakePayload: $e');
    }
  }

  HandshakePayload copyWith({
    int? protocolVersion,
    String? sessionId,
    String? deviceIdHex,
    String? displayName,
    String? platform,
    Set<TransportType>? supportedTransports,
    bool? accepted,
    String? rejectionReason,
    int? timestamp,
    Set<String>? features,
  }) {
    return HandshakePayload(
      protocolVersion: protocolVersion ?? this.protocolVersion,
      sessionId: sessionId ?? this.sessionId,
      deviceIdHex: deviceIdHex ?? this.deviceIdHex,
      displayName: displayName ?? this.displayName,
      platform: platform ?? this.platform,
      supportedTransports: supportedTransports ?? this.supportedTransports,
      accepted: accepted ?? this.accepted,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      timestamp: timestamp ?? this.timestamp,
      features: features ?? this.features,
    );
  }
}
