import '../../models/device.dart';
import 'ble_service.dart';
import 'wifi_service.dart';

/// Phase 2 discovery manager.
/// Mock-only for now; real platform services will be introduced in later steps.
class DiscoveryManager {
  final BleService _bleService;
  final WifiService _wifiService;

  DiscoveryManager({BleService? bleService, WifiService? wifiService})
    : _bleService = bleService ?? BleService(),
      _wifiService = wifiService ?? WifiService();

  Future<List<Device>> discover() async {
    // Mock strategy: return BLE devices first, then WiFi devices appended.
    final bleDevices = await _bleService.startAdvertisingAndScan();
    final wifiDevices = await _wifiService.startDiscovery();
    return [...bleDevices, ...wifiDevices];
  }
}
