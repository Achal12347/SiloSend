/// Common interface for platform-specific hardware/connectivity capabilities.
///
/// Keeps Android-specific and Windows-specific implementations cleanly isolated
/// from shared business logic, transfer engines, and UI.
abstract class PlatformService {
  /// The operating system / platform identifier.
  String get platformName;

  /// Whether Bluetooth Low Energy (BLE) hardware is available and supported.
  Future<bool> isBleSupported();

  /// Whether Wi-Fi Direct / Local Hotspot capability is supported.
  Future<bool> isWifiDirectSupported();

  /// Requests required runtime permissions for nearby device discovery and sharing.
  Future<bool> requestPermissions();
}
