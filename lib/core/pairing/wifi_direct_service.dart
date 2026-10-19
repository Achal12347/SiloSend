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

  /// Whether this phone can join a 5 GHz group (false on 2.4 GHz-only
  /// phones such as the Poco C3, and where Wi-Fi Direct is missing).
  Future<bool> supports5Ghz();

  /// Creates a group (or reports the one already up). Failures use the
  /// hotspot error kinds so screens explain them the same way.
  /// [allow5Ghz] false makes a 2.4 GHz group for a phone without 5 GHz.
  Future<({WifiDirectGroup? group, HotspotStartError? error})> createGroup({
    bool allow5Ghz = true,
  });

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
  Future<bool> supports5Ghz() async => false;
  @override
  Future<({WifiDirectGroup? group, HotspotStartError? error})> createGroup({
    bool allow5Ghz = true,
  }) async => (group: null, error: HotspotStartError.unsupported);
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

  bool? _fiveGhz;

  @override
  Future<bool> supports5Ghz() async {
    final known = _fiveGhz;
    if (known != null) return known;
    try {
      return _fiveGhz =
          await _channel.invokeMethod<bool>('supports5Ghz') ?? false;
    } catch (_) {
      return _fiveGhz = false;
    }
  }

  @override
  Future<({WifiDirectGroup? group, HotspotStartError? error})> createGroup({
    bool allow5Ghz = true,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'createGroup',
        {'allow5Ghz': allow5Ghz},
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
    // Joining ends a group this phone hosted (one group at a time).
    _hosting = false;
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
