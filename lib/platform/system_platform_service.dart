import 'dart:io' show Platform;

import 'package:silosend_datasharing_app/domain/identity/device_capabilities.dart';
import 'package:silosend_datasharing_app/platform/platform_service.dart';

/// Real platform capability provider.
///
/// Strictly complies with the no-mock-data rule:
/// - Never makes static or fabricated claims about physical hardware.
/// - Unprobed radios and sensors are explicitly reported as [CapabilityStatus.unknown]
///   until real native platform channels or plugins are attached.
class SystemPlatformService implements PlatformService {
  final String? platformNameOverride;
  final Future<DeviceCapabilities> Function()? customProbe;

  SystemPlatformService({this.platformNameOverride, this.customProbe});

  @override
  String get platformName {
    final override = platformNameOverride;
    if (override != null) {
      return override;
    }
    try {
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  @override
  Future<DeviceCapabilities> getCapabilities() async {
    final probe = customProbe;
    if (probe != null) {
      return probe();
    }

    // Truthful baseline: Without native platform channels (BLE/Wi-Fi Direct plugins)
    // attached, hardware support cannot be confirmed. We explicitly declare them unknown
    // rather than faking support.
    return const DeviceCapabilities(
      ble: CapabilityStatus.unknown,
      bleAdvertising: CapabilityStatus.unknown,
      wifiDirect: CapabilityStatus.unknown,
      nfc: CapabilityStatus.unknown,
      camera: CapabilityStatus.unknown,
    );
  }

  @override
  Future<bool> isBleSupported() async {
    final capabilities = await getCapabilities();
    return capabilities.supportsBle;
  }

  @override
  Future<bool> isWifiDirectSupported() async {
    final capabilities = await getCapabilities();
    return capabilities.supportsWifiDirect;
  }

  @override
  Future<bool> requestPermissions() async {
    // True permission requests will be handled when native permission channels are wired.
    // We truthfully return false indicating runtime permissions have not been requested/granted.
    return false;
  }
}
