import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/domain/identity/system_capabilities.dart';

void main() {
  group('SystemCapabilities Model Tests', () {
    test('baseline initializes with truthful defaults', () {
      final caps = SystemCapabilities.baseline(platformName: 'android');

      expect(caps.platformName, equals('android'));
      expect(caps.bluetoothState, equals(RadioState.unknown));
      expect(caps.nearbyPermission, equals(PermissionStatus.unknown));
      expect(caps.lanState, equals(NetworkState.unknown));
      expect(caps.canUseLan, isFalse);
      expect(caps.canUseBle, isFalse);
    });

    test('canUseLan is true when LAN network state is available', () {
      const caps = SystemCapabilities(
        platformName: 'android',
        bluetoothState: RadioState.disabled,
        nearbyPermission: PermissionStatus.denied,
        locationRequiredForBle: false,
        locationEnabled: false,
        wifiEnabled: true,
        lanState: NetworkState.lanAvailable,
      );

      expect(caps.canUseLan, isTrue);
      expect(caps.canUseBle, isFalse);
    });

    test('canUseBle requires bluetooth enabled and permissions granted or not required', () {
      // Missing permission
      var caps = const SystemCapabilities(
        platformName: 'android',
        bluetoothState: RadioState.enabled,
        nearbyPermission: PermissionStatus.denied,
        locationRequiredForBle: false,
        lanState: NetworkState.disconnected,
      );
      expect(caps.canUseBle, isFalse);

      // Bluetooth disabled
      caps = const SystemCapabilities(
        platformName: 'android',
        bluetoothState: RadioState.disabled,
        nearbyPermission: PermissionStatus.granted,
        locationRequiredForBle: false,
        lanState: NetworkState.disconnected,
      );
      expect(caps.canUseBle, isFalse);

      // Location required but disabled on legacy Android
      caps = const SystemCapabilities(
        platformName: 'android',
        bluetoothState: RadioState.enabled,
        nearbyPermission: PermissionStatus.granted,
        locationRequiredForBle: true,
        locationEnabled: false,
        lanState: NetworkState.disconnected,
      );
      expect(caps.canUseBle, isFalse);

      // All requirements met on modern Android
      caps = const SystemCapabilities(
        platformName: 'android',
        bluetoothState: RadioState.enabled,
        nearbyPermission: PermissionStatus.granted,
        locationRequiredForBle: false,
        lanState: NetworkState.disconnected,
      );
      expect(caps.canUseBle, isTrue);
    });

    test('parses from native map correctly', () {
      final map = {
        'bluetoothSupported': true,
        'bluetoothEnabled': true,
        'nearbyPermissionStatus': 'granted',
        'locationRequired': false,
        'locationEnabled': false,
        'wifiEnabled': true,
        'lanAvailable': true,
        'sdkVersion': 33,
      };

      final caps = SystemCapabilities.fromMap(map, platform: 'android');

      expect(caps.bluetoothState, equals(RadioState.enabled));
      expect(caps.nearbyPermission, equals(PermissionStatus.granted));
      expect(caps.wifiEnabled, isTrue);
      expect(caps.lanState, equals(NetworkState.lanAvailable));
      expect(caps.sdkVersion, equals(33));
      expect(caps.canUseBle, isTrue);
      expect(caps.canUseLan, isTrue);
    });
  });
}
