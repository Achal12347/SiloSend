import '../../models/device.dart';

/// Phase 2: mock-only BLE service (no real BLE).
class BleService {
  Future<List<Device>> startAdvertisingAndScan() async {
    // Emulate BLE discovery.
    await Future<void>.delayed(const Duration(milliseconds: 700));

    return const [
      Device(id: 'device-ava', name: 'Ava’s Phone', distanceLabel: '1.2 km'),
      Device(id: 'device-mi', name: 'Mi Note', distanceLabel: '780 m'),
    ];
  }
}
