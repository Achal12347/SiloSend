import 'dart:async';

import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

import '../../models/device.dart';

class P2pDiscoveryService {
  final FlutterP2pClient _client;
  final FlutterP2pHost _host;

  StreamSubscription<List<BleDiscoveredDevice>>? _scanSubscription;
  bool _initialized = false;

  P2pDiscoveryService({FlutterP2pClient? client, FlutterP2pHost? host})
    : _client = client ?? FlutterP2pClient(),
      _host = host ?? FlutterP2pHost();

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _client.initialize();
    await _host.initialize();
    _initialized = true;
  }

  Future<void> _ensurePermissions() async {
    await _client.askP2pPermissions();
    await _client.askBluetoothPermissions();
  }

  Future<List<Device>> startDiscovery({
    required void Function(List<Device>) onUpdate,
  }) async {
    await _ensureInitialized();
    await _ensurePermissions();

    if (!await _client.checkWifiEnabled()) {
      await _client.enableWifiServices();
    }

    if (!await _client.checkLocationEnabled()) {
      await _client.enableLocationServices();
    }

    final devicesByAddress = <String, Device>{};

    _scanSubscription = await _client.startScan((devices) {
      for (final device in devices) {
        devicesByAddress[device.deviceAddress] = Device(
          id: device.deviceAddress,
          name: device.deviceName,
          distanceLabel: 'Nearby',
        );
      }
      onUpdate(devicesByAddress.values.toList());
    }, timeout: const Duration(seconds: 15));

    await Future<void>.delayed(const Duration(seconds: 15));
    await stopDiscovery();
    return devicesByAddress.values.toList();
  }

  Future<void> stopDiscovery() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _client.stopScan();
  }

  Future<HotspotHostState> startHosting() async {
    await _ensureInitialized();
    await _ensurePermissions();
    if (!await _client.checkWifiEnabled()) {
      await _client.enableWifiServices();
    }

    return _host.createGroup(advertise: true);
  }

  Future<void> stopHosting() async {
    await _host.removeGroup();
  }

  void dispose() {
    unawaited(stopDiscovery());
    unawaited(stopHosting());
    unawaited(_client.dispose());
    unawaited(_host.dispose());
  }
}
