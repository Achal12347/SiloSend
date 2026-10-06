import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:vayu/core/lifecycle/app_lifecycle_manager.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';

/// User-facing action recommendation for capabilities.
enum CapabilityActionType {
  none,
  requestNearbyPermission,
  enableBluetooth,
  openAppSettings,
  openWifiSettings,
}

/// High-level operational readiness of device connectivity for Vayu.
enum CapabilityOperationalStatus {
  checking,
  readyBoth,
  readyLanOnly,
  readyBleOnly,
  actionRequired,
}

/// Evaluated summary of system capabilities answering:
/// 1. What is happening?
/// 2. What is available?
/// 3. What can I do next?
@immutable
class EvaluatedCapabilityState {
  final SystemCapabilities capabilities;
  final bool isChecking;
  final bool lanOnlyDismissed;

  const EvaluatedCapabilityState({
    required this.capabilities,
    this.isChecking = false,
    this.lanOnlyDismissed = false,
  });

  bool get canUseLan =>
      capabilities.canUseLan ||
      (!Platform.isAndroid && capabilities.platformName != 'android');
  bool get canUseBle => capabilities.canUseBle;
  bool get hasAnyReady => canUseLan || canUseBle;

  CapabilityOperationalStatus get operationalStatus {
    if (isChecking) {
      return CapabilityOperationalStatus.checking;
    }
    if (canUseLan && canUseBle) {
      return CapabilityOperationalStatus.readyBoth;
    }
    if (canUseLan && !canUseBle) {
      return CapabilityOperationalStatus.readyLanOnly;
    }
    if (!canUseLan && canUseBle) {
      return CapabilityOperationalStatus.readyBleOnly;
    }
    return CapabilityOperationalStatus.actionRequired;
  }

  /// What is happening?
  String get statusTitle {
    switch (operationalStatus) {
      case CapabilityOperationalStatus.checking:
        return 'Checking nearby capabilities...';
      case CapabilityOperationalStatus.readyBoth:
        return 'Ready via Wi-Fi and Bluetooth';
      case CapabilityOperationalStatus.readyLanOnly:
        return 'Ready over Local Wi-Fi';
      case CapabilityOperationalStatus.readyBleOnly:
        return 'Ready via Bluetooth Low Energy';
      case CapabilityOperationalStatus.actionRequired:
        return 'Setup Required for Nearby Sharing';
    }
  }

  /// What is available?
  String get availableSummary {
    final parts = <String>[];
    if (canUseLan) {
      parts.add('Local Wi-Fi');
    }
    if (canUseBle) {
      parts.add('Bluetooth Low Energy');
    }
    if (parts.isEmpty) {
      return 'No active discovery transports';
    }
    return parts.join(' & ');
  }

  /// Primary next action to recommend to the user.
  CapabilityActionType get recommendedAction {
    // If user explicitly chose to continue with LAN only and LAN is working, no urgent action
    if (lanOnlyDismissed && canUseLan) {
      return CapabilityActionType.none;
    }

    // If BLE is not ready, prioritize BLE resolution
    if (!canUseBle) {
      if (capabilities.isNearbyPermissionNotRequested ||
          capabilities.nearbyPermission == PermissionStatus.denied) {
        return CapabilityActionType.requestNearbyPermission;
      }
      if (capabilities.isPermanentlyDenied) {
        return CapabilityActionType.openAppSettings;
      }
      if (capabilities.isBluetoothOff) {
        return CapabilityActionType.enableBluetooth;
      }
    }

    // If neither is ready and Wi-Fi is disconnected
    if (!canUseLan && !canUseBle) {
      if (capabilities.lanState == NetworkState.disconnected) {
        return CapabilityActionType.openWifiSettings;
      }
    }

    return CapabilityActionType.none;
  }

  /// Human-friendly description of what can be done next.
  String? get actionDescription {
    switch (recommendedAction) {
      case CapabilityActionType.requestNearbyPermission:
        return 'Allow Nearby Devices access so SiloSend can discover peers via Bluetooth.';
      case CapabilityActionType.enableBluetooth:
        return 'Bluetooth is turned off. Turn it on to find nearby devices without Wi-Fi.';
      case CapabilityActionType.openAppSettings:
        return 'Nearby access is blocked. Android requires enabling it in App Settings.';
      case CapabilityActionType.openWifiSettings:
        return 'Connect to the same Wi-Fi network as nearby devices for high-speed sharing.';
      case CapabilityActionType.none:
        return null;
    }
  }

  /// Label for the recommended action button.
  String? get actionButtonLabel {
    switch (recommendedAction) {
      case CapabilityActionType.requestNearbyPermission:
        return 'Allow Nearby Access';
      case CapabilityActionType.enableBluetooth:
        return 'Turn On Bluetooth';
      case CapabilityActionType.openAppSettings:
        return 'Open Settings';
      case CapabilityActionType.openWifiSettings:
        return 'Wi-Fi Settings';
      case CapabilityActionType.none:
        return null;
    }
  }
}

/// Orchestrates real-time system capabilities, user recovery actions,
/// and automatic lifecycle reconciliation upon returning to Vayu.
class CapabilityCoordinator {
  final PlatformService _platformService;
  final AppLifecycleManager lifecycleManager;
  final Future<void> Function()? onCapabilitiesChanged;

  final StreamController<EvaluatedCapabilityState> _stateController =
      StreamController<EvaluatedCapabilityState>.broadcast();

  EvaluatedCapabilityState _currentState;
  bool _isRefreshing = false;
  bool _lanOnlyDismissed = false;

  CapabilityCoordinator({
    required PlatformService platformService,
    required this.lifecycleManager,
    this.onCapabilitiesChanged,
    SystemCapabilities? initialCapabilities,
  }) : _platformService = platformService,
       _currentState = EvaluatedCapabilityState(
         capabilities:
             initialCapabilities ??
             SystemCapabilities.baseline(
               platformName: platformService.platformName,
             ),
       ) {
    lifecycleManager.addListener(_handleLifecycleChange);
  }

  /// Current evaluated capability state.
  EvaluatedCapabilityState get state => _currentState;

  /// Reactive stream of evaluated capability states.
  Stream<EvaluatedCapabilityState> get stateStream => _stateController.stream;

  /// Underlying raw system capabilities.
  SystemCapabilities get rawCapabilities => _currentState.capabilities;

  /// Probes capabilities from physical platform and reconciles state.
  Future<EvaluatedCapabilityState> refresh() async {
    if (_isRefreshing) return _currentState;
    _isRefreshing = true;

    _updateState(
      _currentState = EvaluatedCapabilityState(
        capabilities: _currentState.capabilities,
        isChecking: true,
        lanOnlyDismissed: _lanOnlyDismissed,
      ),
    );

    try {
      final newCaps = await _platformService.checkCapabilities();
      _currentState = EvaluatedCapabilityState(
        capabilities: newCaps,
        isChecking: false,
        lanOnlyDismissed: _lanOnlyDismissed,
      );
      _updateState(_currentState);

      // Trigger discovery reconciliation callback if state changed
      if (onCapabilitiesChanged != null) {
        await onCapabilitiesChanged!();
      }
    } catch (e, stack) {
      AppLogger.warning(
        'CapabilityCoordinator',
        'Failed to refresh capabilities: $e',
        stackTrace: stack,
      );
      _currentState = EvaluatedCapabilityState(
        capabilities: _currentState.capabilities,
        isChecking: false,
        lanOnlyDismissed: _lanOnlyDismissed,
      );
      _updateState(_currentState);
    } finally {
      _isRefreshing = false;
    }

    return _currentState;
  }

  /// Automatically triggered when application returns to foreground.
  void _handleLifecycleChange(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) {
      AppLogger.info(
        'CapabilityCoordinator',
        'App resumed: automatically re-checking capabilities...',
      );
      refresh().ignore();
    }
  }

  /// Directly requests Android Nearby Devices runtime permission without opening settings.
  Future<PermissionStatus> requestNearbyAccess() async {
    AppLogger.info('CapabilityCoordinator', 'Requesting nearby permission...');
    final status = await _platformService.requestNearbyPermissions();
    await refresh();
    return status;
  }

  /// Prompts user to enable Bluetooth.
  Future<bool> enableBluetooth() async {
    AppLogger.info('CapabilityCoordinator', 'Requesting enable Bluetooth...');
    final enabled = await _platformService.requestEnableBluetooth();
    await refresh();
    return enabled;
  }

  /// Opens Android Application Details Settings.
  Future<void> openAppSettings() async {
    await _platformService.openAppSettings();
  }

  /// Opens Wi-Fi Settings.
  Future<void> openWifiSettings() async {
    await _platformService.openWifiSettings();
  }

  /// Allows the user to proceed using LAN discovery only, suppressing BLE alerts.
  void continueWithLanOnly() {
    _lanOnlyDismissed = true;
    _currentState = EvaluatedCapabilityState(
      capabilities: _currentState.capabilities,
      isChecking: _currentState.isChecking,
      lanOnlyDismissed: true,
    );
    _updateState(_currentState);
  }

  void _updateState(EvaluatedCapabilityState newState) {
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  void dispose() {
    lifecycleManager.removeListener(_handleLifecycleChange);
    _stateController.close();
  }
}
