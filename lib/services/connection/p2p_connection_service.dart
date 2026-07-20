import 'dart:async';
import 'dart:io';

import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

import '../../models/device.dart';
import '../permissions/nearby_device_permission_service.dart';

class P2pConnectionService {
  final FlutterP2pClient _client;
  final NearbyDevicePermissionService _permissionService;
  bool _initialized = false;

  P2pConnectionService({
    FlutterP2pClient? client,
    NearbyDevicePermissionService? permissionService,
  }) : _client = client ?? FlutterP2pClient(),
       _permissionService =
           permissionService ?? NearbyDevicePermissionService();

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _client.initialize();
    _initialized = true;
  }

  Future<void> _ensurePermissions() async {
    await _permissionService.requestConnectionPermissions();
  }

  Future<bool> checkWifiEnabled() {
    return _client.checkWifiEnabled();
  }

  Future<bool> checkBluetoothEnabled() {
    return _client.checkBluetoothEnabled();
  }

  Future<bool> checkLocationEnabled() {
    return _client.checkLocationEnabled();
  }

  Future<bool> enableWifiServices() {
    return _client.enableWifiServices();
  }

  Future<bool> enableBluetoothServices() {
    return _client.enableBluetoothServices();
  }

  Future<bool> enableLocationServices() {
    return _client.enableLocationServices();
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

    if (!await _client.checkBluetoothEnabled()) {
      await _client.enableBluetoothServices();
    }

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

  Stream<String> streamReceivedTexts() {
    return _client.streamReceivedTexts();
  }

  Future<void> sendTextToPeer(String clientId, String text) {
    return _client.sendTextToClient(text, clientId);
  }

  Future<void> broadcastText(String text) {
    return _client.broadcastText(text);
  }

  Future<P2pFileInfo?> sendFileToClient(File file, String clientId) {
    return _client.sendFileToClient(file, clientId);
  }

  Future<P2pFileInfo?> broadcastFile(
    File file, {
    List<String>? excludeClientIds,
  }) {
    return _client.broadcastFile(file, excludeClientIds: excludeClientIds);
  }

  Stream<List<HostedFileInfo>> streamSentFilesInfo() {
    return _client.streamSentFilesInfo();
  }

  Stream<List<ReceivableFileInfo>> streamReceivedFilesInfo() {
    return _client.streamReceivedFilesInfo();
  }

  Future<bool> downloadFile(
    String fileId,
    String saveDirectory, {
    String? customFileName,
    dynamic onProgress,
    int? rangeStart,
    int? rangeEnd,
  }) {
    return _client.downloadFile(
      fileId,
      saveDirectory,
      customFileName: customFileName,
      onProgress: onProgress,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );
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
