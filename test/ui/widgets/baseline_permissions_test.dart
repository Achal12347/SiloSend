import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/main.dart';
import 'package:vayu/platform/platform_service.dart';

class _Platform extends PlatformService {
  PermissionReport report;
  final requested = <PermissionGroup>[];
  final opened = <SettingsPage>[];
  PermissionReport Function()? afterAnswer;

  _Platform(this.report);

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: true,
        supportsNfc: false,
        hasCamera: false,
      );

  @override
  Future<bool> isBleSupported() async => true;

  @override
  Future<bool> isWifiDirectSupported() async => true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<PermissionReport> permissionReport() async => report;

  @override
  Future<PermissionStatus> requestPermissionGroup(PermissionGroup group) async {
    requested.add(group);
    final next = afterAnswer;
    if (next != null) report = next();
    return report.statusOf(group);
  }

  @override
  Future<bool> openSettingsPage(SettingsPage page) async {
    opened.add(page);
    return true;
  }
}

PermissionReport _report({
  required int sdk,
  required PermissionStatus nearby,
  PermissionStatus directWifi = PermissionStatus.notRequired,
  SwitchState location = SwitchState.notNeeded,
}) => PermissionReport(
  permissions: {
    PermissionGroup.nearby: nearby,
    PermissionGroup.directWifi: directWifi,
    PermissionGroup.camera: PermissionStatus.granted,
    PermissionGroup.notifications: PermissionStatus.notRequired,
    PermissionGroup.storage: PermissionStatus.notRequired,
  },
  bluetooth: SwitchState.on,
  wifi: SwitchState.on,
  location: location,
  nfc: SwitchState.on,
  battery: SwitchState.on,
  sdkVersion: sdk,
);

void main() {
  late AppContainer container;

  Future<void> start(
    WidgetTester tester,
    _Platform platform, {
    bool onboarded = true,
    bool alreadyAsked = false,
  }) async {
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 7)),
            displayName: 'Tester',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
        platformService: platform,
        settingsStorage: InMemorySettingsStorage(
          UserSettings(
            onboardingVersion: onboarded
                ? UserSettings.currentOnboardingVersion
                : 0,
            baselinePermissionsAsked: alreadyAsked,
          ),
        ),
      );
      await container.initialize();
    });
    addTearDown(container.dispose);
    await tester.pumpWidget(VayuApp(container: container));
  }

  /// Lets real platform futures finish, then the frames that follow them.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  testWidgets('onboarding asks nothing; Home asks once it opens', (
    tester,
  ) async {
    final platform = _Platform(
      _report(sdk: 34, nearby: PermissionStatus.notRequested),
    );
    await start(tester, platform, onboarded: false);
    await settle(tester);

    await tester.tap(find.text('Skip'));
    await settle(tester);
    expect(find.text('Allow Nearby devices'), findsNothing);

    await tester.tap(find.text('Skip for now'));
    await settle(tester);
    expect(platform.requested, isEmpty);
    expect(find.text('Allow Nearby devices'), findsOneWidget);
    expect(container.userSettings.baselinePermissionsAsked, isTrue);
  });

  testWidgets('Home asks only once', (tester) async {
    final platform = _Platform(
      _report(sdk: 34, nearby: PermissionStatus.notRequested),
    );
    await start(tester, platform, alreadyAsked: true);
    await settle(tester);
    expect(find.text('Allow Nearby devices'), findsNothing);
  });

  testWidgets(
    'allowing Location goes straight on to turning Location on, then closes',
    (tester) async {
      final platform = _Platform(
        _report(
          sdk: 29,
          nearby: PermissionStatus.notRequested,
          location: SwitchState.off,
        ),
      );
      platform.afterAnswer = () => _report(
        sdk: 29,
        nearby: PermissionStatus.granted,
        location: SwitchState.off,
      );
      await start(tester, platform);
      await settle(tester);
      expect(find.text('Allow Location'), findsOneWidget);

      await tester.tap(find.text('Allow'));
      await settle(tester);
      expect(find.text('Turn on Location'), findsWidgets);

      await tester.tap(find.text('Open Location settings'));
      await settle(tester);
      expect(platform.opened, [SettingsPage.location]);

      // Comes back with Location on: the sheet closes by itself.
      platform.report = _report(
        sdk: 29,
        nearby: PermissionStatus.granted,
        location: SwitchState.on,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(find.text('Open Location settings'), findsNothing);
    },
  );

  testWidgets('on Android 13+ the Wi-Fi Direct permission is asked with it', (
    tester,
  ) async {
    final platform = _Platform(
      _report(
        sdk: 34,
        nearby: PermissionStatus.notRequested,
        directWifi: PermissionStatus.notRequested,
      ),
    );
    platform.afterAnswer = () => _report(
      sdk: 34,
      nearby: PermissionStatus.granted,
      directWifi: platform.requested.contains(PermissionGroup.directWifi)
          ? PermissionStatus.granted
          : PermissionStatus.notRequested,
    );
    await start(tester, platform);
    await settle(tester);
    await tester.tap(find.text('Allow'));
    await settle(tester);
    expect(platform.requested, [
      PermissionGroup.nearby,
      PermissionGroup.directWifi,
    ]);
  });

  test('answering does not wait for discovery to restart', () async {
    final platform = _Platform(
      _report(sdk: 34, nearby: PermissionStatus.notRequested),
    );
    final never = Completer<void>();
    final manager = PermissionManager(platform, onChanged: () => never.future);
    await manager
        .request(PermissionGroup.nearby)
        .timeout(const Duration(seconds: 1));
    await manager.recheck().timeout(const Duration(seconds: 1));
  });
}
