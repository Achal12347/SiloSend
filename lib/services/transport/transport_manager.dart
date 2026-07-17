import 'package:battery_plus/battery_plus.dart';

import '../../models/transport_models.dart';
import '../connection/p2p_connection_service.dart';

class SmartTransportManager {
  static const int smallFileThresholdBytes = 1 * 1024 * 1024;
  static const int lowBatteryThreshold = 25;

  final P2pConnectionService _connectionService;
  final Battery _battery;
  final Future<int> Function()? _batteryLevelOverride;
  final Future<bool> Function()? _wifiEnabledOverride;
  final Future<bool> Function()? _bluetoothEnabledOverride;

  SmartTransportManager({
    required P2pConnectionService connectionService,
    Battery? battery,
    Future<int> Function()? batteryLevelOverride,
    Future<bool> Function()? wifiEnabledOverride,
    Future<bool> Function()? bluetoothEnabledOverride,
  }) : _connectionService = connectionService,
       _battery = battery ?? Battery(),
       _batteryLevelOverride = batteryLevelOverride,
       _wifiEnabledOverride = wifiEnabledOverride,
       _bluetoothEnabledOverride = bluetoothEnabledOverride;

  Future<TransferTransportDecision> decideForText() async {
    return TransferTransportDecision(
      mode: TransferTransportMode.chunkedText,
      reason: 'Text uses the lightweight chunked path.',
      wifiEnabled: await _wifiEnabled(),
      bluetoothEnabled: await _bluetoothEnabled(),
      batteryLevel: await _batteryLevel(),
    );
  }

  Future<TransferTransportDecision> decideForFile(int fileSizeBytes) async {
    final wifiEnabled = await _wifiEnabled();
    final bluetoothEnabled = await _bluetoothEnabled();
    final batteryLevel = await _batteryLevel();
    final batteryLow = batteryLevel <= lowBatteryThreshold;
    final isSmallFile = fileSizeBytes <= smallFileThresholdBytes;

    if (batteryLow) {
      return TransferTransportDecision(
        mode: TransferTransportMode.chunkedText,
        reason: 'Battery is low, so we prefer the lighter transfer path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    if (!wifiEnabled && bluetoothEnabled) {
      return TransferTransportDecision(
        mode: TransferTransportMode.chunkedText,
        reason: 'Wi-Fi is unavailable, so we fall back to the lighter path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    if (!bluetoothEnabled && wifiEnabled) {
      return TransferTransportDecision(
        mode: TransferTransportMode.nativeFile,
        reason: 'BLE is unavailable, so we use the Wi-Fi file path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    if (isSmallFile) {
      return TransferTransportDecision(
        mode: TransferTransportMode.chunkedText,
        reason: 'Small files use the lightweight path automatically.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    return TransferTransportDecision(
      mode: TransferTransportMode.nativeFile,
      reason: 'Large files use the native Wi-Fi file transfer path.',
      wifiEnabled: wifiEnabled,
      bluetoothEnabled: bluetoothEnabled,
      batteryLevel: batteryLevel,
    );
  }

  Future<bool> canUseNativeFileTransfer() async {
    final decision = await decideForFile(smallFileThresholdBytes + 1);
    return decision.isNativeFile;
  }

  Future<int> _batteryLevel() async {
    if (_batteryLevelOverride != null) {
      return _batteryLevelOverride!();
    }
    return _battery.batteryLevel;
  }

  Future<bool> _wifiEnabled() async {
    if (_wifiEnabledOverride != null) {
      return _wifiEnabledOverride!();
    }
    return _connectionService.checkWifiEnabled();
  }

  Future<bool> _bluetoothEnabled() async {
    if (_bluetoothEnabledOverride != null) {
      return _bluetoothEnabledOverride!();
    }
    return _connectionService.checkBluetoothEnabled();
  }
}
