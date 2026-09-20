/// Represents the verification status of a hardware capability.
enum CapabilityStatus {
  /// Confirmed supported and available on this device hardware and OS.
  supported,

  /// Confirmed unsupported by the device hardware or OS.
  unsupported,

  /// Hardware exists but is currently disabled or unavailable (e.g. Bluetooth turned off).
  unavailable,

  /// Capability has not been probed or native hardware driver/plugin is not attached.
  unknown;

  /// Whether the capability is confirmed supported.
  bool get isSupported => this == CapabilityStatus.supported;

  /// Human-readable description for UI display.
  String get displayLabel {
    switch (this) {
      case CapabilityStatus.supported:
        return 'Supported';
      case CapabilityStatus.unsupported:
        return 'Unsupported';
      case CapabilityStatus.unavailable:
        return 'Unavailable';
      case CapabilityStatus.unknown:
        return 'Unknown (Not Probed)';
    }
  }
}

/// Represents the physical wireless and hardware capabilities of a device.
///
/// Avoids fake or static hardware claims by explicitly distinguishing between
/// confirmed supported, unsupported, unavailable, and unknown capabilities.
class DeviceCapabilities {
  final CapabilityStatus ble;
  final CapabilityStatus bleAdvertising;
  final CapabilityStatus wifiDirect;
  final CapabilityStatus nfc;
  final CapabilityStatus camera;

  const DeviceCapabilities({
    this.ble = CapabilityStatus.unknown,
    this.bleAdvertising = CapabilityStatus.unknown,
    this.wifiDirect = CapabilityStatus.unknown,
    this.nfc = CapabilityStatus.unknown,
    this.camera = CapabilityStatus.unknown,
  });

  /// Convenience constructor creating capabilities from boolean flags.
  const DeviceCapabilities.fromBooleans({
    required bool supportsBle,
    required bool supportsBleAdvertising,
    required bool supportsWifiDirect,
    required bool supportsNfc,
    required bool hasCamera,
  }) : ble = supportsBle
           ? CapabilityStatus.supported
           : CapabilityStatus.unsupported,
       bleAdvertising = supportsBleAdvertising
           ? CapabilityStatus.supported
           : CapabilityStatus.unsupported,
       wifiDirect = supportsWifiDirect
           ? CapabilityStatus.supported
           : CapabilityStatus.unsupported,
       nfc = supportsNfc
           ? CapabilityStatus.supported
           : CapabilityStatus.unsupported,
       camera = hasCamera
           ? CapabilityStatus.supported
           : CapabilityStatus.unsupported;

  /// Baseline when hardware capabilities have not yet been probed.
  static const unknown = DeviceCapabilities(
    ble: CapabilityStatus.unknown,
    bleAdvertising: CapabilityStatus.unknown,
    wifiDirect: CapabilityStatus.unknown,
    nfc: CapabilityStatus.unknown,
    camera: CapabilityStatus.unknown,
  );

  /// Baseline when all wireless features are confirmed unsupported.
  static const none = DeviceCapabilities(
    ble: CapabilityStatus.unsupported,
    bleAdvertising: CapabilityStatus.unsupported,
    wifiDirect: CapabilityStatus.unsupported,
    nfc: CapabilityStatus.unsupported,
    camera: CapabilityStatus.unsupported,
  );

  // Backward-compatible boolean convenience getters:
  bool get supportsBle => ble.isSupported;
  bool get supportsBleAdvertising => bleAdvertising.isSupported;
  bool get supportsWifiDirect => wifiDirect.isSupported;
  bool get supportsNfc => nfc.isSupported;
  bool get hasCamera => camera.isSupported;
  bool get supportsCamera => camera.isSupported;

  DeviceCapabilities copyWith({
    CapabilityStatus? ble,
    CapabilityStatus? bleAdvertising,
    CapabilityStatus? wifiDirect,
    CapabilityStatus? nfc,
    CapabilityStatus? camera,
  }) {
    return DeviceCapabilities(
      ble: ble ?? this.ble,
      bleAdvertising: bleAdvertising ?? this.bleAdvertising,
      wifiDirect: wifiDirect ?? this.wifiDirect,
      nfc: nfc ?? this.nfc,
      camera: camera ?? this.camera,
    );
  }

  Map<String, dynamic> toJson() => {
    'ble': ble.name,
    'bleAdvertising': bleAdvertising.name,
    'wifiDirect': wifiDirect.name,
    'nfc': nfc.name,
    'camera': camera.name,
    // Legacy boolean keys for backward compatibility:
    'supportsBle': supportsBle,
    'supportsBleAdvertising': supportsBleAdvertising,
    'supportsWifiDirect': supportsWifiDirect,
    'supportsNfc': supportsNfc,
    'hasCamera': hasCamera,
  };

  factory DeviceCapabilities.fromJson(Map<String, dynamic> json) {
    CapabilityStatus parseStatus(String? key, String? legacyKey) {
      if (key != null && json.containsKey(key)) {
        final val = json[key] as String?;
        return CapabilityStatus.values.firstWhere(
          (e) => e.name == val,
          orElse: () => CapabilityStatus.unknown,
        );
      }
      if (legacyKey != null && json.containsKey(legacyKey)) {
        final val = json[legacyKey] as bool? ?? false;
        return val ? CapabilityStatus.supported : CapabilityStatus.unsupported;
      }
      return CapabilityStatus.unknown;
    }

    return DeviceCapabilities(
      ble: parseStatus('ble', 'supportsBle'),
      bleAdvertising: parseStatus('bleAdvertising', 'supportsBleAdvertising'),
      wifiDirect: parseStatus('wifiDirect', 'supportsWifiDirect'),
      nfc: parseStatus('nfc', 'supportsNfc'),
      camera: parseStatus('camera', 'hasCamera'),
    );
  }
}
