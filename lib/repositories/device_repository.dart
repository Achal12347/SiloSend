import '../models/device.dart';

abstract class DeviceRepository {
  /// Returns discovered devices.
  ///
  /// Phase 2: mock-first (no BLE/WiFi implemented yet).
  Future<List<Device>> discoverDevices();
}
