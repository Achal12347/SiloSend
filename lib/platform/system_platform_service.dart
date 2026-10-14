import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';

/// Real platform capability provider.
///
/// Strictly complies with the no-mock-data rule:
/// - Never makes static or fabricated claims about physical hardware.
/// - Unprobed radios and sensors are explicitly reported as [CapabilityStatus.unknown]
///   until real native platform channels or plugins are attached.
class SystemPlatformService implements PlatformService {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/platform',
  );

  final String? platformNameOverride;
  final Future<DeviceCapabilities> Function()? customProbe;
  final Future<SystemCapabilities> Function()? customCapabilitiesProbe;

  /// Test hook that forces the Android code path on non-Android test hosts.
  final bool? isAndroidOverride;

  SystemPlatformService({
    this.platformNameOverride,
    this.customProbe,
    this.customCapabilitiesProbe,
    this.isAndroidOverride,
  });

  bool get _isActualAndroid {
    final override = isAndroidOverride;
    if (override != null) return override;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

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

    // Truthful baseline: Without native platform channels attached,
    // hardware support cannot be confirmed. We explicitly declare them unknown
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
  Future<SystemCapabilities> checkCapabilities() async {
    final probe = customCapabilitiesProbe;
    if (probe != null) {
      return probe();
    }

    if (!_isActualAndroid) {
      return SystemCapabilities.baseline(platformName: platformName);
    }

    try {
      final res = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('checkCapabilities')
          .timeout(const Duration(seconds: 2));
      if (res != null) {
        return SystemCapabilities.fromMap(res, platform: platformName);
      }
    } on MissingPluginException {
      // Unintegrated or test harness baseline
    } on PlatformException {
      // Channel failure
    } catch (_) {}

    return SystemCapabilities.baseline(platformName: platformName);
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

  // Shared by every caller so a second tap while the system dialog is open
  // waits for the same answer instead of failing with ALREADY_REQUESTING.
  Future<PermissionStatus>? _pendingNearbyRequest;
  Future<bool>? _pendingEnableBluetooth;

  @override
  Future<PermissionStatus> requestNearbyPermissions() {
    return _pendingNearbyRequest ??= _requestNearbyPermissionsOnce()
        .whenComplete(() => _pendingNearbyRequest = null);
  }

  Future<PermissionStatus> _requestNearbyPermissionsOnce() async {
    if (!_isActualAndroid) {
      return PermissionStatus.denied;
    }

    try {
      // No timeout: the call completes only when the user answers the system
      // permission dialog, which routinely takes longer than a few seconds.
      final statusStr = await _channel.invokeMethod<String>(
        'requestNearbyPermissions',
      );
      switch (statusStr) {
        case 'granted':
          return PermissionStatus.granted;
        case 'permanently_denied':
          return PermissionStatus.permanentlyDenied;
        case 'denied':
          return PermissionStatus.denied;
        case 'not_required':
          return PermissionStatus.notRequired;
        default:
          return PermissionStatus.unknown;
      }
    } on MissingPluginException {
      return PermissionStatus.denied;
    } on PlatformException {
      return PermissionStatus.denied;
    } catch (_) {
      return PermissionStatus.denied;
    }
  }

  @override
  Future<bool> requestEnableBluetooth() {
    return _pendingEnableBluetooth ??= _requestEnableBluetoothOnce()
        .whenComplete(() => _pendingEnableBluetooth = null);
  }

  Future<bool> _requestEnableBluetoothOnce() async {
    if (!_isActualAndroid) {
      return false;
    }

    try {
      // No timeout: waits for the user to answer the system Bluetooth dialog.
      return await _channel.invokeMethod<bool>('enableBluetooth') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> openAppSettings() async {
    if (!_isActualAndroid) return;
    try {
      await _channel
          .invokeMethod<void>('openAppSettings')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> openLocationSettings() async {
    if (!_isActualAndroid) return;
    try {
      await _channel
          .invokeMethod<void>('openLocationSettings')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> openWifiSettings() async {
    if (!_isActualAndroid) return;
    try {
      await _channel
          .invokeMethod<void>('openWifiSettings')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<bool> openFile(String filePath, {String? mimeType}) async {
    if (!_isActualAndroid) return false;
    try {
      return await _channel
              .invokeMethod<bool>('openFile', {
                'path': filePath,
                'mimeType': mimeType ?? '*/*',
              })
              .timeout(const Duration(seconds: 2)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> acquireMulticastLock() async {
    if (!_isActualAndroid) return;
    try {
      await _channel
          .invokeMethod<void>('acquireMulticastLock')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> releaseMulticastLock() async {
    if (!_isActualAndroid) return;
    try {
      await _channel
          .invokeMethod<void>('releaseMulticastLock')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<bool> requestPermissions() async {
    final status = await requestNearbyPermissions();
    return status == PermissionStatus.granted;
  }
}
