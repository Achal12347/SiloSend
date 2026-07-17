import '../../models/device.dart';

/// Phase 2: mock-only WiFi Direct service (no real WiFi).
class WifiService {
  Future<List<Device>> startDiscovery() async {
    // Emulate WiFi discovery.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    return const [
      Device(id: 'device-sam', name: 'Sam’s Tablet', distanceLabel: '2.4 km'),
    ];
  }
}
