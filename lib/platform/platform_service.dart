import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/permission_report.dart';
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

  /// Every permission and system switch Vayu depends on.
  Future<PermissionReport> permissionReport() async =>
      PermissionReport.notApplicable();

  /// Shows the system dialog for [group] (queued behind any other dialog).
  Future<PermissionStatus> requestPermissionGroup(
    PermissionGroup group,
  ) async => PermissionStatus.notRequired;

  /// Opens a tel:, mailto: or http(s): link in the dialer, mail app or
  /// browser. False when nothing could open it.
  Future<bool> openUri(Uri uri) async => false;

  /// Opens [page] in system settings. False if no page could be opened.
  Future<bool> openSettingsPage(SettingsPage page) async => false;

  /// Opens a verified completed file in the host system's default viewer.
  Future<bool> openFile(String filePath, {String? mimeType}) async => true;

  /// Acquires Android Wi-Fi MulticastLock and WifiLock for reliable UDP discovery.
  Future<void> acquireMulticastLock() async {}

  /// Releases Android Wi-Fi MulticastLock and WifiLock.
  Future<void> releaseMulticastLock() async {}

  /// Band and negotiated speed of the current Wi-Fi connection (speed
  /// diagnostics). Null when not on Wi-Fi or unknown.
  Future<WifiLinkInfo?> wifiLinkInfo() async => null;

  /// Android's thermal state ("none" ... "shutdown", Android 10+). Null when
  /// the platform does not report it.
  Future<String?> thermalStatus() async => null;

  /// Keeps the screen from turning off while [on] (screens that answer NFC
  /// taps: Android stops answering once the screen is off).
  Future<void> keepScreenOn(bool on) async {}

  /// Backward-compatible boolean permission requester.
  Future<bool> requestPermissions();
}

/// The phone's current Wi-Fi link as Android reports it.
class WifiLinkInfo {
  final int frequencyMhz;
  final int linkSpeedMbps;
  final int? txLinkSpeedMbps;
  final int? rxLinkSpeedMbps;
  final int rssi;

  const WifiLinkInfo({
    required this.frequencyMhz,
    required this.linkSpeedMbps,
    this.txLinkSpeedMbps,
    this.rxLinkSpeedMbps,
    required this.rssi,
  });

  String get band => frequencyMhz >= 5900
      ? '6 GHz'
      : frequencyMhz >= 4900
      ? '5 GHz'
      : frequencyMhz > 0
      ? '2.4 GHz'
      : 'unknown band';

  /// "5 GHz, 433 Mbps, -52 dBm".
  String summary() {
    final speeds = txLinkSpeedMbps != null && rxLinkSpeedMbps != null
        ? 'send $txLinkSpeedMbps / receive $rxLinkSpeedMbps Mbps'
        : '$linkSpeedMbps Mbps';
    return '$band, $speeds, $rssi dBm';
  }

  static WifiLinkInfo? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    int? asInt(Object? v) => v is int ? v : null;
    final frequency = asInt(map['frequencyMhz']);
    final speed = asInt(map['linkSpeedMbps']);
    if (frequency == null || speed == null) return null;
    return WifiLinkInfo(
      frequencyMhz: frequency,
      linkSpeedMbps: speed,
      txLinkSpeedMbps: asInt(map['txLinkSpeedMbps']),
      rxLinkSpeedMbps: asInt(map['rxLinkSpeedMbps']),
      rssi: asInt(map['rssi']) ?? 0,
    );
  }
}
