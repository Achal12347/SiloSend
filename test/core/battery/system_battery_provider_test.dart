import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/battery/battery_snapshot.dart';
import 'package:silosend_datasharing_app/core/battery/system_battery_provider.dart';

void main() {
  group('BatterySnapshot Model Tests', () {
    test('creates unknown snapshot with all null values', () {
      final snapshot = BatterySnapshot.unknown();
      expect(snapshot.batteryLevel, isNull);
      expect(snapshot.isCharging, isNull);
      expect(snapshot.isBatterySaverActive, isNull);
      expect(snapshot.isUnknown, isTrue);
      expect(snapshot.isKnown, isFalse);
      expect(snapshot.isLowBattery, isFalse);
      expect(snapshot.isCriticalBattery, isFalse);
    });

    test('correctly evaluates low and critical battery conditions', () {
      final highCharging = BatterySnapshot(
        batteryLevel: 85,
        isCharging: true,
        isBatterySaverActive: false,
        timestamp: DateTime.now(),
      );
      expect(highCharging.isLowBattery, isFalse);
      expect(highCharging.isCriticalBattery, isFalse);

      final lowDischarging = BatterySnapshot(
        batteryLevel: 25,
        isCharging: false,
        isBatterySaverActive: false,
        timestamp: DateTime.now(),
      );
      expect(lowDischarging.isLowBattery, isTrue);
      expect(lowDischarging.isCriticalBattery, isFalse);

      final criticalDischarging = BatterySnapshot(
        batteryLevel: 10,
        isCharging: false,
        isBatterySaverActive: true,
        timestamp: DateTime.now(),
      );
      expect(criticalDischarging.isLowBattery, isTrue);
      expect(criticalDischarging.isCriticalBattery, isTrue);

      // Low battery but plugged in -> isLowBattery is false (not discharging)
      final lowCharging = BatterySnapshot(
        batteryLevel: 12,
        isCharging: true,
        isBatterySaverActive: false,
        timestamp: DateTime.now(),
      );
      expect(lowCharging.isLowBattery, isFalse);
      expect(lowCharging.isCriticalBattery, isFalse);
    });
  });

  group('SystemBatteryProvider Tests', () {
    test(
      'truthfully reports unknown when probe returns null or missing channel',
      () async {
        final provider = SystemBatteryProvider(
          customNativeProbe: () async => null,
        );

        final snapshot = await provider.getBatterySnapshot();
        expect(snapshot.isUnknown, isTrue);
        expect(await provider.getBatteryLevel(), isNull);
        expect(await provider.isCharging(), isNull);
        expect(await provider.isBatterySaverActive(), isNull);
      },
    );

    test('parses real native probe response with clamping', () async {
      int queryCount = 0;
      final provider = SystemBatteryProvider(
        customNativeProbe: () async {
          queryCount++;
          return {
            'level': 78,
            'isCharging': false,
            'isBatterySaverActive': false,
          };
        },
      );

      final snapshot = await provider.getBatterySnapshot();
      expect(snapshot.isKnown, isTrue);
      expect(snapshot.batteryLevel, 78);
      expect(snapshot.isCharging, isFalse);
      expect(snapshot.isBatterySaverActive, isFalse);
      expect(queryCount, 1);

      // Subsequent query within TTL returns cached instance without re-querying
      final cached = await provider.getBatterySnapshot();
      expect(cached.batteryLevel, 78);
      expect(queryCount, 1);

      // Cache invalidation triggers fresh query
      provider.invalidateCache();
      final fresh = await provider.getBatterySnapshot();
      expect(fresh.batteryLevel, 78);
      expect(queryCount, 2);
    });

    test(
      'handles probe exceptions gracefully without fabricating values',
      () async {
        final provider = SystemBatteryProvider(
          customNativeProbe: () async => throw Exception('Native error'),
        );

        final snapshot = await provider.getBatterySnapshot();
        expect(snapshot.isUnknown, isTrue);
        expect(snapshot.batteryLevel, isNull);
      },
    );
  });
}
