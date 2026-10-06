import 'package:flutter/foundation.dart';

/// Status of a runtime permission.
enum PermissionStatus {
  granted,
  denied,
  permanentlyDenied,
  notRequested,
  notRequired,
  unknown;

  bool get isGranted => this == PermissionStatus.granted;
  bool get isNotRequested => this == PermissionStatus.notRequested;
  bool get isPermanentlyDenied => this == PermissionStatus.permanentlyDenied;
  bool get isDenied => this == PermissionStatus.denied;
}

/// Hardware radio state (e.g. Bluetooth).
enum RadioState {
  enabled,
  disabled,
  unsupported,
  unknown;

  bool get isEnabled => this == RadioState.enabled;
}

/// Local area network (LAN/Wi-Fi) connectivity state.
enum NetworkState {
  lanAvailable,
  disconnected,
  unknown;

  bool get isAvailable => this == NetworkState.lanAvailable;
}

/// Comprehensive, truthful snapshot of platform hardware, radios, permissions,
/// and local network status.
@immutable
class SystemCapabilities {
  final String platformName;
  final RadioState bluetoothState;
  final PermissionStatus nearbyPermission;
  final bool locationRequiredForBle;
  final bool locationEnabled;
  final bool wifiEnabled;
  final NetworkState lanState;
  final int? sdkVersion;

  const SystemCapabilities({
    this.platformName = 'unknown',
    this.bluetoothState = RadioState.unknown,
    this.nearbyPermission = PermissionStatus.unknown,
    this.locationRequiredForBle = false,
    this.locationEnabled = false,
    this.wifiEnabled = false,
    this.lanState = NetworkState.unknown,
    this.sdkVersion,
  });

  /// Baseline fallback when unprobed or running in mock-free test harnesses.
  factory SystemCapabilities.baseline({String platformName = 'unknown'}) {
    return SystemCapabilities(platformName: platformName);
  }

  /// Parses native platform channel map from `PlatformHandler.kt`.
  factory SystemCapabilities.fromMap(
    Map<dynamic, dynamic> map, {
    String platform = 'android',
  }) {
    final btSupported = map['bluetoothSupported'] == true;
    final btEnabled = map['bluetoothEnabled'] == true;

    final RadioState btState;
    if (!btSupported) {
      btState = RadioState.unsupported;
    } else if (btEnabled) {
      btState = RadioState.enabled;
    } else {
      btState = RadioState.disabled;
    }

    final nearbyStatusStr = map['nearbyPermissionStatus'] as String?;
    final PermissionStatus nearbyStatus;
    switch (nearbyStatusStr) {
      case 'granted':
        nearbyStatus = PermissionStatus.granted;
        break;
      case 'permanently_denied':
        nearbyStatus = PermissionStatus.permanentlyDenied;
        break;
      case 'not_requested':
        nearbyStatus = PermissionStatus.notRequested;
        break;
      case 'denied':
        nearbyStatus = PermissionStatus.denied;
        break;
      case 'not_required':
        nearbyStatus = PermissionStatus.notRequired;
        break;
      default:
        nearbyStatus = PermissionStatus.unknown;
    }

    final locReq = map['locationRequired'] == true;
    final locEnabled = map['locationEnabled'] == true;
    final wifiOn = map['wifiEnabled'] == true;
    final lanAvail = map['lanAvailable'] == true;
    final sdk = map['sdkVersion'] as int?;

    return SystemCapabilities(
      platformName: platform,
      bluetoothState: btState,
      nearbyPermission: nearbyStatus,
      locationRequiredForBle: locReq,
      locationEnabled: locEnabled,
      wifiEnabled: wifiOn,
      lanState: lanAvail
          ? NetworkState.lanAvailable
          : NetworkState.disconnected,
      sdkVersion: sdk,
    );
  }

  /// Whether Bluetooth Low Energy (BLE) discovery/connection is genuinely ready.
  bool get canUseBle {
    if (bluetoothState != RadioState.enabled) return false;
    if (nearbyPermission != PermissionStatus.granted &&
        nearbyPermission != PermissionStatus.notRequired) {
      return false;
    }
    if (locationRequiredForBle && !locationEnabled) {
      return false;
    }
    return true;
  }

  /// Whether Local Area Network (LAN) discovery/connection is genuinely ready.
  bool get canUseLan => lanState == NetworkState.lanAvailable;

  /// Whether at least one physical transport (LAN or BLE) can currently operate.
  bool get hasAnyTransportAvailable => canUseBle || canUseLan;

  /// Whether Bluetooth radio hardware exists but is currently powered off.
  bool get isBluetoothOff => bluetoothState == RadioState.disabled;

  /// Whether Bluetooth hardware does not exist on this device.
  bool get isBluetoothUnsupported => bluetoothState == RadioState.unsupported;

  /// Whether Nearby / Bluetooth permissions need to be requested or allowed.
  bool get isNearbyPermissionMissing =>
      nearbyPermission == PermissionStatus.notRequested ||
      nearbyPermission == PermissionStatus.denied ||
      nearbyPermission == PermissionStatus.permanentlyDenied;

  /// Whether Nearby permissions have never been requested yet.
  bool get isNearbyPermissionNotRequested =>
      nearbyPermission == PermissionStatus.notRequested;

  /// Whether Nearby permissions have been permanently denied by the user.
  bool get isPermanentlyDenied =>
      nearbyPermission == PermissionStatus.permanentlyDenied;

  SystemCapabilities copyWith({
    String? platformName,
    RadioState? bluetoothState,
    PermissionStatus? nearbyPermission,
    bool? locationRequiredForBle,
    bool? locationEnabled,
    bool? wifiEnabled,
    NetworkState? lanState,
    int? sdkVersion,
  }) {
    return SystemCapabilities(
      platformName: platformName ?? this.platformName,
      bluetoothState: bluetoothState ?? this.bluetoothState,
      nearbyPermission: nearbyPermission ?? this.nearbyPermission,
      locationRequiredForBle:
          locationRequiredForBle ?? this.locationRequiredForBle,
      locationEnabled: locationEnabled ?? this.locationEnabled,
      wifiEnabled: wifiEnabled ?? this.wifiEnabled,
      lanState: lanState ?? this.lanState,
      sdkVersion: sdkVersion ?? this.sdkVersion,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SystemCapabilities &&
        other.platformName == platformName &&
        other.bluetoothState == bluetoothState &&
        other.nearbyPermission == nearbyPermission &&
        other.locationRequiredForBle == locationRequiredForBle &&
        other.locationEnabled == locationEnabled &&
        other.wifiEnabled == wifiEnabled &&
        other.lanState == lanState &&
        other.sdkVersion == sdkVersion;
  }

  @override
  int get hashCode => Object.hash(
    platformName,
    bluetoothState,
    nearbyPermission,
    locationRequiredForBle,
    locationEnabled,
    wifiEnabled,
    lanState,
    sdkVersion,
  );
}
