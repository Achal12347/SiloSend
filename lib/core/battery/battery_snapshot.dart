/// Immutable snapshot of device battery state.
///
/// Strictly adheres to the Vayu No Mock Data principle:
/// When running on unsupported platforms (e.g. desktop), unprobed hardware,
/// or in headless test environments without platform channels, fields are explicitly
/// `null` rather than fabricated with fake numbers or simulated charging states.
class BatterySnapshot {
  /// Current battery level percentage (0 to 100), or `null` if unknown/unsupported.
  final int? batteryLevel;

  /// Whether the device is currently connected to power and charging, or `null` if unknown.
  final bool? isCharging;

  /// Whether the OS low-power or battery-saver mode is active, or `null` if unknown.
  final bool? isBatterySaverActive;

  /// Timestamp when this snapshot was acquired.
  final DateTime timestamp;

  const BatterySnapshot({
    this.batteryLevel,
    this.isCharging,
    this.isBatterySaverActive,
    required this.timestamp,
  });

  /// Factory producing a completely unknown snapshot (truthful baseline for unprobed environments).
  factory BatterySnapshot.unknown() => BatterySnapshot(
    batteryLevel: null,
    isCharging: null,
    isBatterySaverActive: null,
    timestamp: DateTime.now(),
  );

  /// Whether any battery state is known.
  bool get isKnown =>
      batteryLevel != null ||
      isCharging != null ||
      isBatterySaverActive != null;

  /// Whether the battery state is completely unknown.
  bool get isUnknown => !isKnown;

  /// Whether battery level is considered low (<= 30%) and actively discharging.
  bool get isLowBattery =>
      batteryLevel != null && batteryLevel! <= 30 && isCharging != true;

  /// Whether battery level is critically low (<= 15%) and actively discharging.
  bool get isCriticalBattery =>
      batteryLevel != null && batteryLevel! <= 15 && isCharging != true;

  /// Returns a copy of this snapshot with updated fields.
  BatterySnapshot copyWith({
    int? batteryLevel,
    bool? isCharging,
    bool? isBatterySaverActive,
    DateTime? timestamp,
  }) => BatterySnapshot(
    batteryLevel: batteryLevel ?? this.batteryLevel,
    isCharging: isCharging ?? this.isCharging,
    isBatterySaverActive: isBatterySaverActive ?? this.isBatterySaverActive,
    timestamp: timestamp ?? this.timestamp,
  );

  @override
  String toString() =>
      'BatterySnapshot(level: $batteryLevel%, charging: $isCharging, saver: $isBatterySaverActive, at: $timestamp)';
}
