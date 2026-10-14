import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';

/// Real platform battery provider communicating with native OS capabilities.
///
/// Strictly adheres to the No Mock Data rule:
/// - On Android, queries native [BatteryManager] and [PowerManager] via platform channel.
/// - In unprobed, test, or unsupported environments, explicitly returns null fields
///   via [BatterySnapshot.unknown()] rather than fabricating fake hardware state.
class SystemBatteryProvider implements BatteryStateProvider {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/battery',
  );
  static const Duration _cacheTtl = Duration(seconds: 10);

  final Future<Map<String, dynamic>?> Function()? customNativeProbe;
  BatterySnapshot? _cachedSnapshot;

  SystemBatteryProvider({this.customNativeProbe});

  bool get _isActualAndroid {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int?> getBatteryLevel() async {
    final snapshot = await getBatterySnapshot();
    return snapshot.batteryLevel;
  }

  @override
  Future<bool?> isCharging() async {
    final snapshot = await getBatterySnapshot();
    return snapshot.isCharging;
  }

  @override
  Future<bool?> isBatterySaverActive() async {
    final snapshot = await getBatterySnapshot();
    return snapshot.isBatterySaverActive;
  }

  @override
  Future<BatterySnapshot> getBatterySnapshot() async {
    final now = DateTime.now();
    final cached = _cachedSnapshot;
    if (cached != null && now.difference(cached.timestamp) < _cacheTtl) {
      return cached;
    }

    try {
      final probe = customNativeProbe;
      Map<dynamic, dynamic>? rawState;
      if (probe != null) {
        rawState = await probe();
      } else if (!_isActualAndroid) {
        final unknown = BatterySnapshot.unknown();
        _cachedSnapshot = unknown;
        return unknown;
      } else {
        rawState = await _channel
            .invokeMapMethod<String, dynamic>('getBatteryState')
            .timeout(const Duration(seconds: 2));
      }

      if (rawState == null) {
        final unknown = BatterySnapshot.unknown();
        _cachedSnapshot = unknown;
        return unknown;
      }

      final level = rawState['level'] as int?;
      final isCharging = rawState['isCharging'] as bool?;
      final isSaver = rawState['isBatterySaverActive'] as bool?;

      final snapshot = BatterySnapshot(
        batteryLevel: level?.clamp(0, 100),
        isCharging: isCharging,
        isBatterySaverActive: isSaver,
        timestamp: now,
      );
      _cachedSnapshot = snapshot;
      return snapshot;
    } on MissingPluginException {
      // Platform channel not registered (e.g. desktop runner or headless tests).
      // Truthfully report unknown state without fabricating values.
      final unknown = BatterySnapshot.unknown();
      _cachedSnapshot = unknown;
      return unknown;
    } catch (e) {
      AppLogger.warning(
        'SystemBatteryProvider',
        'Failed to query native battery state: $e',
      );
      final unknown = BatterySnapshot.unknown();
      _cachedSnapshot = unknown;
      return unknown;
    }
  }

  /// Invalidates the local TTL cache to force a fresh native query.
  void invalidateCache() {
    _cachedSnapshot = null;
  }
}
