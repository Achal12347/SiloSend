/// Represents the physical wireless and hardware capabilities of a device.
class DeviceCapabilities {
  final bool supportsBle;
  final bool supportsBleAdvertising;
  final bool supportsWifiDirect;
  final bool supportsNfc;
  final bool hasCamera;

  const DeviceCapabilities({
    required this.supportsBle,
    required this.supportsBleAdvertising,
    required this.supportsWifiDirect,
    required this.supportsNfc,
    required this.hasCamera,
  });

  /// Minimal capability baseline when detection is pending or unavailable.
  static const none = DeviceCapabilities(
    supportsBle: false,
    supportsBleAdvertising: false,
    supportsWifiDirect: false,
    supportsNfc: false,
    hasCamera: false,
  );

  Map<String, dynamic> toJson() => {
    'supportsBle': supportsBle,
    'supportsBleAdvertising': supportsBleAdvertising,
    'supportsWifiDirect': supportsWifiDirect,
    'supportsNfc': supportsNfc,
    'hasCamera': hasCamera,
  };

  factory DeviceCapabilities.fromJson(Map<String, dynamic> json) {
    return DeviceCapabilities(
      supportsBle: json['supportsBle'] as bool? ?? false,
      supportsBleAdvertising: json['supportsBleAdvertising'] as bool? ?? false,
      supportsWifiDirect: json['supportsWifiDirect'] as bool? ?? false,
      supportsNfc: json['supportsNfc'] as bool? ?? false,
      hasCamera: json['hasCamera'] as bool? ?? false,
    );
  }
}
