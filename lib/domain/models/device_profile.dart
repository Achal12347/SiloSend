/// Represents the verified identity of a SiloSend device.
///
/// Per AI/AGENTS.md, this must always be populated with real device data,
/// never mock or fabricated values.
class DeviceProfile {
  /// Unique device identifier (UUID or cryptographic fingerprint).
  final String id;

  /// User-visible device display name.
  final String displayName;

  /// Supported SiloSend protocol version.
  final int protocolVersion;

  /// Underlying platform name (e.g. Android, Windows).
  final String platform;

  const DeviceProfile({
    required this.id,
    required this.displayName,
    required this.protocolVersion,
    required this.platform,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'protocolVersion': protocolVersion,
    'platform': platform,
  };

  factory DeviceProfile.fromJson(Map<String, dynamic> json) {
    return DeviceProfile(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      protocolVersion: json['protocolVersion'] as int,
      platform: json['platform'] as String,
    );
  }
}
