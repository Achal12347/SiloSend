import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/constants/app_constants.dart';

/// Represents the persistent local device identity for Vayu.
///
/// Contains a 16-byte (128-bit) unique identifier generated on first launch
/// that matches the wire packet framing requirements.
///
/// NOTE: The [deviceId] is a public routing identifier, NOT a secret or
/// authentication credential. Cryptographic authentication, session keys,
/// and proof of identity are established independently in the Secure Session layer.
class LocalDeviceIdentity {
  /// Exactly 16 bytes representing the public unique device routing identifier.
  final Uint8List deviceId;

  /// User-visible device display name.
  final String displayName;

  /// Operating system / platform identifier.
  final String platform;

  /// Vayu protocol version supported by this identity.
  final int protocolVersion;

  /// Timestamp when this device identity was first created.
  final DateTime createdAt;

  LocalDeviceIdentity({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    this.protocolVersion = AppConstants.protocolVersion,
    required this.createdAt,
  }) {
    if (deviceId.length != 16) {
      throw ArgumentError.value(
        deviceId.length,
        'deviceId',
        'Device ID must be exactly 16 bytes',
      );
    }
    if (displayName.trim().isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'Display name cannot be empty',
      );
    }
  }

  /// Formats the 16-byte device ID as a canonical 32-character hex string.
  String get idHex =>
      deviceId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Formats the 16-byte device ID as a standard UUID (8-4-4-4-12 format).
  String get uuid {
    final hex = idHex;
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// Generates a new cryptographically random 16-byte device identity.
  static LocalDeviceIdentity generate({
    required String displayName,
    required String platform,
  }) {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    // Set UUID version 4 and variant bits for standard compatibility
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 1 (RFC 4122)

    return LocalDeviceIdentity(
      deviceId: bytes,
      displayName: displayName.trim(),
      platform: platform,
      protocolVersion: AppConstants.protocolVersion,
      createdAt: DateTime.now().toUtc(),
    );
  }

  /// Returns a copy of this identity with modified fields.
  LocalDeviceIdentity copyWith({
    String? displayName,
    String? platform,
    int? protocolVersion,
  }) {
    return LocalDeviceIdentity(
      deviceId: deviceId,
      displayName: displayName ?? this.displayName,
      platform: platform ?? this.platform,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'deviceId': idHex,
    'displayName': displayName,
    'platform': platform,
    'protocolVersion': protocolVersion,
    'createdAt': createdAt.toIso8601String(),
  };

  factory LocalDeviceIdentity.fromJson(Map<String, dynamic> json) {
    final hexString = json['deviceId'] as String;
    if (hexString.length != 32) {
      throw FormatException(
        'Invalid deviceId hex string length: ${hexString.length}',
      );
    }

    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(hexString.substring(i * 2, i * 2 + 2), radix: 16);
    }

    return LocalDeviceIdentity(
      deviceId: bytes,
      displayName: json['displayName'] as String,
      platform: json['platform'] as String,
      protocolVersion:
          json['protocolVersion'] as int? ?? AppConstants.protocolVersion,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}
