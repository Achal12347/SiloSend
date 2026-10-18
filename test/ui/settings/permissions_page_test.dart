import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';
import 'package:vayu/ui/settings/permissions_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

class _FakePlatform extends PlatformService {
  PermissionReport report;
  final requested = <PermissionGroup>[];
  final opened = <SettingsPage>[];
  PermissionStatus Function(PermissionGroup group) answer;

  _FakePlatform(this.report, this.answer);

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: false,
        supportsNfc: true,
        hasCamera: true,
      );

  @override
  Future<bool> isBleSupported() async => true;

  @override
  Future<bool> isWifiDirectSupported() async => false;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<PermissionReport> permissionReport() async => report;

  @override
  Future<PermissionStatus> requestPermissionGroup(PermissionGroup group) async {
    requested.add(group);
    return answer(group);
  }

  @override
  Future<bool> openSettingsPage(SettingsPage page) async {
    opened.add(page);
    return true;
  }
}

PermissionReport _report({
  PermissionStatus nearby = PermissionStatus.granted,
  PermissionStatus camera = PermissionStatus.notRequested,
  SwitchState nfc = SwitchState.on,
  SwitchState location = SwitchState.notNeeded,
}) => PermissionReport(
  permissions: {
    PermissionGroup.nearby: nearby,
    PermissionGroup.directWifi: PermissionStatus.granted,
    PermissionGroup.camera: camera,
    PermissionGroup.notifications: PermissionStatus.granted,
    PermissionGroup.storage: PermissionStatus.notRequired,
  },
  bluetooth: SwitchState.on,
  wifi: SwitchState.on,
  location: location,
  nfc: nfc,
  battery: SwitchState.off,
  sdkVersion: 34,
);

void main() {
  late AppContainer container;
  late _FakePlatform platform;

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 3)),
            displayName: 'Tester',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
        platformService: platform,
      );
      await container.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        home: PermissionsPage(container: container),
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() => container.dispose());

  testWidgets('shows each item with its state and hides what is not needed', (
    tester,
  ) async {
    platform = _FakePlatform(_report(), (_) => PermissionStatus.granted);
    await pumpPage(tester);

    expect(find.text('Nearby devices'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Not asked yet'), findsOneWidget);
    // Storage is not needed on this Android version, nor is Location.
    expect(find.text('Storage'), findsNothing);
    expect(find.text('Location'), findsNothing);
    expect(find.text('Optimised'), findsOneWidget);
  });

  testWidgets('Allow asks in the app first', (tester) async {
    platform = _FakePlatform(_report(), (_) => PermissionStatus.granted);
    await pumpPage(tester);

    platform.report = _report(camera: PermissionStatus.granted);
    final allow = find.widgetWithText(FilledButton, 'Allow');
    await tester.ensureVisible(allow);
    await tester.pumpAndSettle();
    await tester.tap(allow);
    await tester.pumpAndSettle();

    expect(platform.requested, [PermissionGroup.camera]);
    expect(platform.opened, isEmpty);
    expect(find.text('Allow'), findsNothing);
  });

  testWidgets('a blocked permission opens the app settings page', (
    tester,
  ) async {
    platform = _FakePlatform(
      _report(camera: PermissionStatus.permanentlyDenied),
      (_) => PermissionStatus.permanentlyDenied,
    );
    await pumpPage(tester);

    expect(find.text('Blocked'), findsOneWidget);
    final open = find.widgetWithText(FilledButton, 'Open settings').first;
    await tester.ensureVisible(open);
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();

    expect(platform.requested, isEmpty);
    expect(platform.opened, [SettingsPage.app]);
  });

  testWidgets('NFC off opens the NFC settings page', (tester) async {
    platform = _FakePlatform(
      _report(camera: PermissionStatus.granted, nfc: SwitchState.off),
      (_) => PermissionStatus.granted,
    );
    await pumpPage(tester);

    final turnOn = find.widgetWithText(FilledButton, 'Turn on');
    await tester.ensureVisible(turnOn);
    await tester.pumpAndSettle();
    await tester.tap(turnOn);
    await tester.pumpAndSettle();
    expect(platform.opened, [SettingsPage.nfc]);
  });
}
