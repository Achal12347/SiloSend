import 'package:silosend_datasharing_app/core/battery/battery_snapshot.dart';

/// Abstract contract providing real-time device battery metrics.
///
/// Used by the Smart Transport Selector to prevent power-hungry operations
/// when battery is low or battery saver is active.
///
/// Strictly complies with the No Mock Data rule: when running in an unprobed
/// or unsupported environment, methods return `null` instead of fabricated values.
abstract class BatteryStateProvider {
  /// Returns the current battery percentage (0 to 100), or `null` if unknown/unsupported.
  Future<int?> getBatteryLevel();

  /// Whether the device is currently plugged in and charging, or `null` if unknown/unsupported.
  Future<bool?> isCharging();

  /// Whether the operating system's low-power / battery-saver mode is active, or `null` if unknown.
  Future<bool?> isBatterySaverActive();

  /// Obtains a consolidated snapshot of the current device battery state.
  Future<BatterySnapshot> getBatterySnapshot();
}
