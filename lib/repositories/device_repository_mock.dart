import '../models/device.dart';
import 'device_repository.dart';

class MockDeviceRepository implements DeviceRepository {
  @override
  Future<List<Device>> discoverDevices() async {
    // Phase 2 mock-first: emulate discovery delay and return two devices.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    return const [
      Device(id: 'device-ava', name: 'Ava’s Phone', distanceLabel: '1.2 km'),
      Device(id: 'device-mi', name: 'Mi Note', distanceLabel: '780 m'),
    ];
  }
}
