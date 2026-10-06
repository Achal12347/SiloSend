import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/platform/platform_service.dart';
import 'package:vayu/ui/home/capability_setup_banner.dart';

class _FakeBannerPlatformService extends PlatformService {
  SystemCapabilities caps;
  bool appSettingsOpened = false;
  bool bluetoothEnableRequested = false;

  _FakeBannerPlatformService(this.caps);

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: false,
        supportsNfc: false,
        hasCamera: false,
      );

  @override
  Future<SystemCapabilities> checkCapabilities() async => caps;

  @override
  Future<bool> isBleSupported() async => caps.bluetoothState.isEnabled;

  @override
  Future<bool> isWifiDirectSupported() async => false;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<void> openAppSettings() async {
    appSettingsOpened = true;
  }

  @override
  Future<bool> requestEnableBluetooth() async {
    bluetoothEnableRequested = true;
    return true;
  }
}

void main() {
  testWidgets(
    'CapabilitySetupBanner is hidden when both BLE and LAN are ready',
    (tester) async {
      final fakePlatform = _FakeBannerPlatformService(
        const SystemCapabilities(
          platformName: 'android',
          bluetoothState: RadioState.enabled,
          nearbyPermission: PermissionStatus.granted,
          locationRequiredForBle: false,
          locationEnabled: false,
          wifiEnabled: true,
          lanState: NetworkState.lanAvailable,
        ),
      );

      final container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 1)),
            displayName: 'TestDev',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
        platformService: fakePlatform,
      );
      await container.initialize();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CapabilitySetupBanner(container: container)),
        ),
      );
      await tester.pump();

      // No banner should appear
      expect(find.byType(CapabilitySetupBanner), findsOneWidget);
      expect(find.text('Bluetooth is Turned Off'), findsNothing);
      expect(find.text('Nearby Device Permission Required'), findsNothing);

      container.dispose();
    },
  );

  testWidgets(
    'CapabilitySetupBanner shows Bluetooth prompt and allows LAN continuation',
    (tester) async {
      final fakePlatform = _FakeBannerPlatformService(
        const SystemCapabilities(
          platformName: 'android',
          bluetoothState: RadioState.disabled,
          nearbyPermission: PermissionStatus.granted,
          locationRequiredForBle: false,
          locationEnabled: false,
          wifiEnabled: true,
          lanState: NetworkState.lanAvailable,
        ),
      );

      final container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 1)),
            displayName: 'TestDev',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
        platformService: fakePlatform,
      );
      await container.initialize();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CapabilitySetupBanner(container: container)),
        ),
      );
      await tester.pump();

      expect(find.text('Bluetooth is Turned Off'), findsOneWidget);
      expect(find.text('Turn On Bluetooth'), findsOneWidget);
      expect(find.text('Continue with LAN Only'), findsOneWidget);

      // Tap 'Continue with LAN Only' to dismiss without blocking LAN
      await tester.tap(find.text('Continue with LAN Only'));
      await tester.pump();

      expect(find.text('Bluetooth is Turned Off'), findsNothing);

      container.dispose();
    },
  );
}
