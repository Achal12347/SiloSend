import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';

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

  /// Comprehensive real-time probe of Bluetooth radio, permissions, Wi-Fi, and LAN.
  Future<SystemCapabilities> checkCapabilities() async =>
      SystemCapabilities.baseline(platformName: platformName);

  /// Whether Bluetooth Low Energy (BLE) hardware is confirmed available and supported.
  Future<bool> isBleSupported();

  /// Whether Wi-Fi Direct / Local Hotspot capability is confirmed supported.
  Future<bool> isWifiDirectSupported();

  /// Requests required runtime permissions for nearby device discovery and sharing.
  ///
  /// Returns a granular [PermissionStatus].
  Future<PermissionStatus> requestNearbyPermissions() async =>
      PermissionStatus.granted;

  /// Prompts the user to turn on Bluetooth if disabled.
  Future<bool> requestEnableBluetooth() async => true;

  /// Navigates to app settings so user can adjust permissions.
  Future<void> openAppSettings() async {}

  /// Navigates to location settings (relevant on legacy Android).
  Future<void> openLocationSettings() async {}

  /// Navigates to Wi-Fi / connectivity settings.
  Future<void> openWifiSettings() async {}

  /// Opens a verified completed file in the host system's default viewer.
  Future<bool> openFile(String filePath, {String? mimeType}) async => true;

  /// Acquires Android Wi-Fi MulticastLock and WifiLock for reliable UDP discovery.
  Future<void> acquireMulticastLock() async {}

  /// Releases Android Wi-Fi MulticastLock and WifiLock.
  Future<void> releaseMulticastLock() async {}

  /// Backward-compatible boolean permission requester.
  Future<bool> requestPermissions();
}
