import 'package:battery_plus/battery_plus.dart';

import '../../models/transport_models.dart';
import '../connection/p2p_connection_service.dart';

class SmartTransportManager {
  static const int smallFileThresholdBytes = 1 * 1024 * 1024;
  static const int lowBatteryThreshold = 25;

  final P2pConnectionService connectionService;
  final Battery _battery;
  final Future<int> Function()? batteryLevelOverride;
  final Future<bool> Function()? wifiEnabledOverride;
  final Future<bool> Function()? bluetoothEnabledOverride;

  SmartTransportManager({
    required this.connectionService,
    Battery? battery,
    this.batteryLevelOverride,
    this.wifiEnabledOverride,
    this.bluetoothEnabledOverride,
  }) : _battery = battery ?? Battery();

  Future<TransferTransportDecision> decideForText() async {
    final wifiEnabled = await _wifiEnabled();
    final bluetoothEnabled = await _bluetoothEnabled();
    final batteryLevel = await _batteryLevel();

    if (!bluetoothEnabled && wifiEnabled) {
      return _buildDecision(
        mode: TransferTransportMode.nativeFile,
        reason: 'BLE is unavailable, so text falls back to the Wi-Fi path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    if (batteryLevel <= lowBatteryThreshold) {
      return _buildDecision(
        mode: TransferTransportMode.chunkedText,
        reason: 'Battery is low, so text stays on the lightweight path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    return _buildDecision(
      mode: TransferTransportMode.chunkedText,
      reason: 'Text uses the lightweight chunked path.',
      wifiEnabled: wifiEnabled,
      bluetoothEnabled: bluetoothEnabled,
      batteryLevel: batteryLevel,
    );
  }

  Future<TransferTransportDecision> decideForFile(int fileSizeBytes) async {
    final wifiEnabled = await _wifiEnabled();
    final bluetoothEnabled = await _bluetoothEnabled();
    final batteryLevel = await _batteryLevel();
    final batteryLow = batteryLevel <= lowBatteryThreshold;
    final isSmallFile = fileSizeBytes <= smallFileThresholdBytes;

    if (!bluetoothEnabled && wifiEnabled) {
      return _buildDecision(
        mode: TransferTransportMode.nativeFile,
        reason: 'BLE is unavailable, so we use the Wi-Fi file path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    if (!wifiEnabled && bluetoothEnabled) {
      return _buildDecision(
        mode: TransferTransportMode.chunkedText,
        reason: 'Wi-Fi is unavailable, so we fall back to the lighter path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    if (batteryLow && bluetoothEnabled) {
      return _buildDecision(
        mode: TransferTransportMode.chunkedText,
        reason: 'Battery is low, so we prefer the lighter transfer path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    if (!wifiEnabled && !bluetoothEnabled) {
      return _buildDecision(
        mode: isSmallFile
            ? TransferTransportMode.chunkedText
            : TransferTransportMode.nativeFile,
        reason: isSmallFile
            ? 'Neither radio is reported as available, so we keep the lighter file path.'
            : 'Neither radio is reported as available, so we keep the file transfer path.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    if (isSmallFile) {
      return _buildDecision(
        mode: TransferTransportMode.chunkedText,
        reason: 'Small files use the lightweight path automatically.',
        wifiEnabled: wifiEnabled,
        bluetoothEnabled: bluetoothEnabled,
        batteryLevel: batteryLevel,
      );
    }

    return _buildDecision(
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
    final override = batteryLevelOverride;
    if (override != null) {
      return override();
    }
    return _battery.batteryLevel;
  }

  TransferTransportDecision _buildDecision({
    required TransferTransportMode mode,
    required String reason,
    required bool wifiEnabled,
    required bool bluetoothEnabled,
    required int batteryLevel,
  }) {
    return TransferTransportDecision(
      mode: mode,
      reason: reason,
      wifiEnabled: wifiEnabled,
      bluetoothEnabled: bluetoothEnabled,
      batteryLevel: batteryLevel,
    );
  }

  Future<bool> _wifiEnabled() async {
    final override = wifiEnabledOverride;
    if (override != null) {
      return override();
    }
    return connectionService.checkWifiEnabled();
  }

  Future<bool> _bluetoothEnabled() async {
    final override = bluetoothEnabledOverride;
    if (override != null) {
      return override();
    }
    return connectionService.checkBluetoothEnabled();
  }
}
