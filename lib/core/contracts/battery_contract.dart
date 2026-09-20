/// Abstract contract providing real-time device battery metrics.
///
/// Used by the Smart Transport Selector to prevent power-hungry operations
/// (e.g. Wi-Fi Direct Hotspot) when battery is low or battery saver is active.
abstract class BatteryStateProvider {
  /// Returns the current battery percentage (0 to 100).
  Future<int> getBatteryLevel();

  /// Whether the device is currently plugged in and charging.
  Future<bool> isCharging();

  /// Whether the operating system's low-power / battery-saver mode is active.
  Future<bool> isBatterySaverActive();
}
