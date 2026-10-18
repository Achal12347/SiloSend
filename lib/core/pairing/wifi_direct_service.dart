import 'package:flutter/services.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';

/// A Wi-Fi Direct group this phone hosts.
class WifiDirectGroup {
  final HotspotCredentials credentials;

  /// Channel frequency, for diagnostics (0 when unknown).
  final int frequencyMhz;

  const WifiDirectGroup({required this.credentials, this.frequencyMhz = 0});
}

/// Phone-to-phone Wi-Fi Direct (Android 10+): the fast direct path.
///
/// Used like the hotspot: it puts both phones on one network, then the
/// normal LAN transport carries the transfer. Unlike a shared router, data
/// crosses the air once, and on 5 GHz when the phones can.
abstract class WifiDirectService {
  /// Whether this phone can host and join groups with chosen credentials.
  Future<bool> isSupported();

  bool get isHosting;

  /// Creates a group (or reports the one already up). Failures use the
  /// hotspot error kinds so screens explain them the same way.
  Future<({WifiDirectGroup? group, HotspotStartError? error})> createGroup();

  Future<void> removeGroup();

  /// Joins a group; returns the group owner's address, or null on failure.
  Future<String?> connect({
    required String networkName,
    required String passphrase,
  });

  Future<void> disconnect();
}

/// Platforms without Wi-Fi Direct (desktop, tests, Android 8-9).
class UnsupportedWifiDirectService implements WifiDirectService {
  const UnsupportedWifiDirectService();
  @override
  Future<bool> isSupported() async => false;
  @override
  bool get isHosting => false;
  @override
  Future<({WifiDirectGroup? group, HotspotStartError? error})>
  createGroup() async => (group: null, error: HotspotStartError.unsupported);
  @override
  Future<void> removeGroup() async {}
  @override
  Future<String?> connect({
    required String networkName,
    required String passphrase,
  }) async => null;
  @override
  Future<void> disconnect() async {}
}

/// Android implementation over channel `com.achyrio.vayu/wifi_direct`.
class AndroidWifiDirectService implements WifiDirectService {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/wifi_direct',
  );

  bool _hosting = false;
  bool? _supported;

  @override
  bool get isHosting => _hosting;

  @override
  Future<bool> isSupported() async {
    final known = _supported;
    if (known != null) return known;
    try {
      return _supported =
          await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return _supported = false;
    }
  }

  @override
  Future<({WifiDirectGroup? group, HotspotStartError? error})>
  createGroup() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'createGroup',
      );
      if (result == null) {
        return (group: null, error: HotspotStartError.failed);
      }
      _hosting = true;
      return (
        group: WifiDirectGroup(
          credentials: HotspotCredentials(
            ssid: result['networkName'] as String,
            passphrase: result['passphrase'] as String? ?? '',
            hostAddress: result['hostAddress'] as String?,
          ),
          frequencyMhz: result['frequencyMhz'] as int? ?? 0,
        ),
        error: null,
      );
    } on PlatformException catch (e) {
      AppLogger.warning('WifiDirect', 'Creating a group failed: ${e.code}');
      final error = switch (e.code) {
        'PERMISSION_DENIED' => HotspotStartError.permissionDenied,
        'LOCATION_OFF' => HotspotStartError.locationOff,
        'UNSUPPORTED' => HotspotStartError.unsupported,
        _ => HotspotStartError.failed,
      };
      return (group: null, error: error);
    } on MissingPluginException {
      return (group: null, error: HotspotStartError.unsupported);
    }
  }

  @override
  Future<void> removeGroup() async {
    _hosting = false;
    try {
      await _channel.invokeMethod<bool>('removeGroup');
    } catch (_) {}
  }

  @override
  Future<String?> connect({
    required String networkName,
    required String passphrase,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'connect',
        {'networkName': networkName, 'passphrase': passphrase},
      );
      return result?['groupOwnerAddress'] as String?;
    } catch (e) {
      AppLogger.warning('WifiDirect', 'Joining a group failed: $e');
      return null;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod<bool>('disconnect');
    } catch (_) {}
  }
}
