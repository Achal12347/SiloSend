import 'package:flutter_test/flutter_test.dart';
import 'package:silosend/models/transport_models.dart';
import 'package:silosend/services/connection/p2p_connection_service.dart';
import 'package:silosend/services/transport/transport_manager.dart';

class _FakeConnectionService extends P2pConnectionService {
  final bool wifiEnabled;
  final bool bluetoothEnabled;

  _FakeConnectionService({
    required this.wifiEnabled,
    required this.bluetoothEnabled,
  });

  @override
  Future<bool> checkWifiEnabled() async => wifiEnabled;

  @override
  Future<bool> checkBluetoothEnabled() async => bluetoothEnabled;
}

SmartTransportManager _manager({
  required bool wifiEnabled,
  required bool bluetoothEnabled,
  required int batteryLevel,
}) {
  return SmartTransportManager(
    connectionService: _FakeConnectionService(
      wifiEnabled: wifiEnabled,
      bluetoothEnabled: bluetoothEnabled,
    ),
    batteryLevelOverride: () async => batteryLevel,
  );
}

void main() {
  test('uses the lightweight path for text by default', () async {
    final decision = await _manager(
      wifiEnabled: true,
      bluetoothEnabled: true,
      batteryLevel: 80,
    ).decideForText();

    expect(decision.mode, TransferTransportMode.chunkedText);
    expect(decision.label, 'Lightweight chunked path');
  });

  test('falls back to Wi-Fi path for text when BLE is unavailable', () async {
    final decision = await _manager(
      wifiEnabled: true,
      bluetoothEnabled: false,
      batteryLevel: 80,
    ).decideForText();

    expect(decision.mode, TransferTransportMode.nativeFile);
    expect(decision.reason, contains('BLE is unavailable'));
  });

  test('uses the lightweight path for small files', () async {
    final decision = await _manager(
      wifiEnabled: true,
      bluetoothEnabled: true,
      batteryLevel: 80,
    ).decideForFile(SmartTransportManager.smallFileThresholdBytes);

    expect(decision.mode, TransferTransportMode.chunkedText);
    expect(decision.reason, contains('Small files'));
  });

  test('uses the native file path for large files', () async {
    final decision = await _manager(
      wifiEnabled: true,
      bluetoothEnabled: true,
      batteryLevel: 80,
    ).decideForFile(SmartTransportManager.smallFileThresholdBytes + 1);

    expect(decision.mode, TransferTransportMode.nativeFile);
    expect(decision.reason, contains('Large files'));
  });

  test('falls back to the lightweight path when battery is low', () async {
    final decision = await _manager(
      wifiEnabled: true,
      bluetoothEnabled: true,
      batteryLevel: SmartTransportManager.lowBatteryThreshold,
    ).decideForFile(SmartTransportManager.smallFileThresholdBytes + 1);

    expect(decision.mode, TransferTransportMode.chunkedText);
    expect(decision.reason, contains('Battery is low'));
  });

  test(
    'prefers Wi-Fi path when BLE is unavailable even if battery is low',
    () async {
      final decision = await _manager(
        wifiEnabled: true,
        bluetoothEnabled: false,
        batteryLevel: SmartTransportManager.lowBatteryThreshold,
      ).decideForFile(SmartTransportManager.smallFileThresholdBytes + 1);

      expect(decision.mode, TransferTransportMode.nativeFile);
      expect(decision.reason, contains('BLE is unavailable'));
    },
  );

  test(
    'prefers lightweight path when Wi-Fi is unavailable even if battery is low',
    () async {
      final decision = await _manager(
        wifiEnabled: false,
        bluetoothEnabled: true,
        batteryLevel: SmartTransportManager.lowBatteryThreshold,
      ).decideForFile(SmartTransportManager.smallFileThresholdBytes + 1);

      expect(decision.mode, TransferTransportMode.chunkedText);
      expect(decision.reason, contains('Wi-Fi is unavailable'));
    },
  );
}
