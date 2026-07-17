import '../models/device.dart';
import '../services/discovery/discovery_manager.dart';
import 'device_repository.dart';

class MockDeviceRepository implements DeviceRepository {
  final DiscoveryManager _discoveryManager;

  MockDeviceRepository({DiscoveryManager? discoveryManager})
    : _discoveryManager = discoveryManager ?? DiscoveryManager();

  @override
  Future<List<Device>> discoverDevices() async {
    return _discoveryManager.discover();
  }
}
