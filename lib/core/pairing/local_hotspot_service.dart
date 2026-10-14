import 'package:flutter/services.dart';

import 'package:vayu/core/logging/app_logger.dart';

/// Credentials of a phone-hosted local-only Wi-Fi network.
class HotspotCredentials {
  final String ssid;
  final String passphrase;

  /// This phone's address on the hotspot, where peers reach the LAN server.
  final String? hostAddress;

  const HotspotCredentials({
    required this.ssid,
    required this.passphrase,
    this.hostAddress,
  });
}

/// Outcome of trying to start a hotspot, so the UI can explain failures.
enum HotspotStartError {
  permissionDenied,
  locationOff,
  tetheringActive,
  unsupported,
  failed,
}

class HotspotStartResult {
  final HotspotCredentials? credentials;
  final HotspotStartError? error;

  const HotspotStartResult.success(HotspotCredentials this.credentials)
    : error = null;
  const HotspotStartResult.failure(HotspotStartError this.error)
    : credentials = null;

  bool get isSuccess => credentials != null;
}

/// Phone-to-phone Wi-Fi without a router.
///
/// Used when two phones share no network: one hosts an Android LocalOnlyHotspot
/// (no internet, no tethering) and the other joins it, after which the normal
/// LAN transport carries the transfer at Wi-Fi speed instead of Bluetooth.
abstract class LocalHotspotService {
  bool get isHosting;
  Future<HotspotStartResult> start();
  Future<void> stop();

  /// Joins a peer's hotspot. Returns false when the user or system declined.
  Future<bool> join({required String ssid, required String passphrase});

  /// Releases a joined hotspot so the phone returns to its normal network.
  Future<void> leave();
}

/// Platforms without hotspot support (desktop, tests).
class UnsupportedHotspotService implements LocalHotspotService {
  const UnsupportedHotspotService();
  @override
  bool get isHosting => false;
  @override
  Future<HotspotStartResult> start() async =>
      const HotspotStartResult.failure(HotspotStartError.unsupported);
  @override
  Future<void> stop() async {}
  @override
  Future<bool> join({required String ssid, required String passphrase}) async =>
      false;
  @override
  Future<void> leave() async {}
}

/// Android implementation over channel `com.achyrio.vayu/hotspot`.
class AndroidHotspotService implements LocalHotspotService {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/hotspot',
  );

  bool _hosting = false;

  @override
  bool get isHosting => _hosting;

  @override
  Future<HotspotStartResult> start() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('start');
      if (result == null) {
        return const HotspotStartResult.failure(HotspotStartError.failed);
      }
      _hosting = true;
      return HotspotStartResult.success(
        HotspotCredentials(
          ssid: result['ssid'] as String,
          passphrase: result['passphrase'] as String? ?? '',
          hostAddress: result['hostAddress'] as String?,
        ),
      );
    } on PlatformException catch (e) {
      AppLogger.warning('Hotspot', 'Hotspot start failed: ${e.code}');
      final error = switch (e.code) {
        'PERMISSION_DENIED' => HotspotStartError.permissionDenied,
        'LOCATION_OFF' => HotspotStartError.locationOff,
        'INCOMPATIBLE_MODE' => HotspotStartError.tetheringActive,
        'UNSUPPORTED' => HotspotStartError.unsupported,
        _ => HotspotStartError.failed,
      };
      return HotspotStartResult.failure(error);
    } on MissingPluginException {
      return const HotspotStartResult.failure(HotspotStartError.unsupported);
    }
  }

  @override
  Future<void> stop() async {
    _hosting = false;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {}
  }

  @override
  Future<bool> join({required String ssid, required String passphrase}) async {
    try {
      // No timeout: Android 10+ shows a system "connect to device" dialog.
      return await _channel.invokeMethod<bool>('join', {
            'ssid': ssid,
            'passphrase': passphrase,
          }) ??
          false;
    } catch (e) {
      AppLogger.warning('Hotspot', 'Joining hotspot failed: $e');
      return false;
    }
  }

  @override
  Future<void> leave() async {
    try {
      await _channel.invokeMethod<bool>('leave');
    } catch (_) {}
  }
}
