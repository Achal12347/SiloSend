import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

class NearbyDevicePermissionException implements Exception {
  final String message;

  const NearbyDevicePermissionException(this.message);

  @override
  String toString() => message;
}

class NearbyDevicePermissionService {
  Future<void> requestNearbyPermissions() async {
    if (!Platform.isAndroid) return;

    final granted = await _request([
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ]);

    if (!granted) {
      throw const NearbyDevicePermissionException(
        'Nearby device permissions are required.',
      );
    }
  }

  Future<void> requestDiscoveryPermissions() async {
    if (!Platform.isAndroid) return;

    final granted = await _request([
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ]);

    if (!granted) {
      throw const NearbyDevicePermissionException(
        'Nearby device permissions are required to scan and host.',
      );
    }
  }

  Future<void> requestConnectionPermissions() async {
    if (!Platform.isAndroid) return;

    final granted = await _request([
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ]);

    if (!granted) {
      throw const NearbyDevicePermissionException(
        'Nearby device permissions are required to connect.',
      );
    }
  }

  Future<bool> _request(List<Permission> permissions) async {
    var allGranted = true;

    for (final permission in permissions) {
      final status = await permission.status;
      if (status.isGranted || status.isLimited) {
        continue;
      }

      final result = await permission.request();
      if (!result.isGranted && !result.isLimited) {
        allGranted = false;
      }
    }

    return allGranted;
  }
}
