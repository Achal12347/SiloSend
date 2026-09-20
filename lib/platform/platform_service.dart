import 'package:silosend_datasharing_app/domain/identity/device_capabilities.dart';

/// Common interface for platform-specific hardware/connectivity capabilities.
///
/// Keeps Android-specific and Windows-specific implementations cleanly isolated
/// from shared business logic, transfer engines, and UI.
abstract class PlatformService {
  /// The operating system / platform identifier (e.g., 'android', 'windows').
  String get platformName;

  /// Probes physical hardware and returns truthful capability status.
  ///
  /// Unverified or unprobed features are returned with [CapabilityStatus.unknown]
  /// or [CapabilityStatus.unavailable] rather than fabricated claims.
  Future<DeviceCapabilities> getCapabilities();

  /// Whether Bluetooth Low Energy (BLE) hardware is confirmed available and supported.
  Future<bool> isBleSupported();

  /// Whether Wi-Fi Direct / Local Hotspot capability is confirmed supported.
  Future<bool> isWifiDirectSupported();

  /// Requests required runtime permissions for nearby device discovery and sharing.
  Future<bool> requestPermissions();
}
