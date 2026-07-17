import 'dart:async';

import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

import '../../models/device.dart';

class P2pConnectionService {
  final FlutterP2pClient _client;
  bool _initialized = false;

  P2pConnectionService({FlutterP2pClient? client})
    : _client = client ?? FlutterP2pClient();

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _client.initialize();
    _initialized = true;
  }

  Future<void> _ensurePermissions() async {
    await _client.askP2pPermissions();
    await _client.askBluetoothPermissions();
  }

  Future<void> validateDevice(Device device) async {
    if (device.id.isEmpty) {
      throw Exception('Device validation failed');
    }
  }

  Future<void> connect(
    Device device, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await _ensureInitialized();
    await _ensurePermissions();
    await validateDevice(device);

    if (!await _client.checkWifiEnabled()) {
      await _client.enableWifiServices();
    }

    if (!await _client.checkLocationEnabled()) {
      await _client.enableLocationServices();
    }

    final bleDevice = BleDiscoveredDevice(
      deviceAddress: device.id,
      deviceName: device.name,
    );
    await _client.connectWithDevice(bleDevice, timeout: timeout);
  }

  Future<void> disconnect() async {
    await _client.disconnect();
  }

  Future<void> reconnect(Device device) async {
    await disconnect();
    await connect(device);
  }

  bool get isConnected => _client.isConnected;

  void dispose() {
    unawaited(_client.dispose());
  }
}
