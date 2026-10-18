import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/permission_report.dart';
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

  final openedPages = <SettingsPage>[];

  @override
  Future<bool> openSettingsPage(SettingsPage page) async {
    openedPages.add(page);
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
      expect(find.text('Bluetooth is off'), findsNothing);
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

      expect(find.text('Bluetooth is off'), findsOneWidget);
      expect(find.text('Turn on Bluetooth'), findsOneWidget);
      expect(find.text('Use Wi-Fi only'), findsOneWidget);

      // Tap 'Use Wi-Fi only' to dismiss without blocking LAN
      await tester.tap(find.text('Use Wi-Fi only'));
      await tester.pump();

      expect(find.text('Bluetooth is off'), findsNothing);

      container.dispose();
    },
  );

  testWidgets(
    'Android 10 with Location off offers Turn on Location, not "unavailable"',
    (tester) async {
      final fakePlatform = _FakeBannerPlatformService(
        const SystemCapabilities(
          platformName: 'android',
          bluetoothState: RadioState.enabled,
          nearbyPermission: PermissionStatus.granted,
          locationRequiredForBle: true,
          locationEnabled: false,
          wifiEnabled: true,
          lanState: NetworkState.lanAvailable,
          sdkVersion: 29,
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

      expect(find.text('Location is off'), findsOneWidget);
      expect(find.textContaining('Android 10'), findsOneWidget);
      expect(find.text("Bluetooth isn't available"), findsNothing);

      await tester.tap(find.text('Turn on Location'));
      await tester.pump();
      expect(fakePlatform.openedPages, [SettingsPage.location]);

      container.dispose();
    },
  );
}
