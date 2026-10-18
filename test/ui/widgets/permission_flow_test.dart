import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/permission_flow.dart';

class _FakePlatform extends PlatformService {
  PermissionReport report;
  final requested = <PermissionGroup>[];
  final opened = <SettingsPage>[];

  /// The report after the user answers the system dialog.
  PermissionReport Function()? afterAnswer;

  _FakePlatform(this.report);

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: true,
        supportsNfc: true,
        hasCamera: true,
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
  int sdk = 29,
  PermissionStatus nearby = PermissionStatus.granted,
  PermissionStatus camera = PermissionStatus.granted,
  SwitchState location = SwitchState.on,
}) => PermissionReport(
  permissions: {
    PermissionGroup.nearby: nearby,
    PermissionGroup.directWifi: PermissionStatus.notRequired,
    PermissionGroup.camera: camera,
    PermissionGroup.notifications: PermissionStatus.notRequired,
    PermissionGroup.storage: PermissionStatus.granted,
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
  late _FakePlatform platform;

  /// Screen with one button that runs the flow and records its answer: the
  /// stand-in for "the action the user asked for".
  Future<List<bool>> pumpScreen(
    WidgetTester tester,
    VayuFeature feature, {
    bool alreadyExplained = false,
  }) async {
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 5)),
            displayName: 'Tester',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
        platformService: platform,
      );
      await container.initialize();
    });
    final results = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(
                await ensureFeature(
                  context,
                  container,
                  feature,
                  alreadyExplained: alreadyExplained,
                ),
              ),
              child: const Text('Do it'),
            ),
          ),
        ),
      ),
    );
    return results;
  }

  Future<void> comeBackFromSettings(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    // Resuming also opens the app's 2-minute search window; end it so the
    // test leaves no timer behind.
    container.endDiscoveryWindow();
    await tester.pumpAndSettle();
  }

  tearDown(() => container.dispose());

  testWidgets('ready features run at once, with no sheet and no dialog', (
    tester,
  ) async {
    platform = _FakePlatform(_report());
    final results = await pumpScreen(tester, VayuFeature.findPhones);
    await tester.tap(find.text('Do it'));
    await tester.pumpAndSettle();

    expect(results, [true]);
    expect(platform.requested, isEmpty);
    expect(find.byType(PermissionFixSheet), findsNothing);
  });

  testWidgets('explains first, asks only after Allow, then continues', (
    tester,
  ) async {
    platform = _FakePlatform(_report(nearby: PermissionStatus.notRequested))
      ..afterAnswer = () => _report();
    final results = await pumpScreen(tester, VayuFeature.findPhones);
    await tester.tap(find.text('Do it'));
    await tester.pumpAndSettle();

    // Android 10 calls it Location; the reason is shown before any dialog.
    expect(find.text('Allow Location'), findsOneWidget);
    expect(find.textContaining('never reads your location'), findsOneWidget);
    expect(platform.requested, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await tester.pumpAndSettle();

    expect(platform.requested, [PermissionGroup.nearby]);
    expect(results, [true]);
    expect(find.byType(PermissionFixSheet), findsNothing);
  });

  testWidgets('Not now leaves without asking', (tester) async {
    platform = _FakePlatform(_report(nearby: PermissionStatus.notRequested));
    final results = await pumpScreen(tester, VayuFeature.findPhones);
    await tester.tap(find.text('Do it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(results, [false]);
    expect(platform.requested, isEmpty);
  });

  testWidgets(
    'blocked: never asks again, opens settings, continues on return',
    (tester) async {
      platform = _FakePlatform(
        _report(camera: PermissionStatus.permanentlyDenied),
      );
      final results = await pumpScreen(tester, VayuFeature.scanCode);
      await tester.tap(find.text('Do it'));
      await tester.pumpAndSettle();

      expect(find.text('Camera is blocked'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Open settings'));
      await tester.pumpAndSettle();
      expect(platform.opened, [SettingsPage.app]);
      expect(find.textContaining('Come back to Vayu'), findsOneWidget);
      expect(results, isEmpty);

      // The user allowed it in Settings and comes back.
      platform.report = _report();
      await comeBackFromSettings(tester);

      expect(platform.requested, isEmpty);
      expect(results, [true]);
    },
  );

  testWidgets('returning without fixing keeps the sheet open', (tester) async {
    platform = _FakePlatform(_report(camera: PermissionStatus.permanentlyDenied));
    final results = await pumpScreen(tester, VayuFeature.scanCode);
    await tester.tap(find.text('Do it'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Open settings'));
    await tester.pumpAndSettle();

    await comeBackFromSettings(tester);

    expect(results, isEmpty);
    expect(find.text('Camera is blocked'), findsOneWidget);
  });

  testWidgets('refusing in the dialog turns the sheet into Open settings', (
    tester,
  ) async {
    platform = _FakePlatform(_report(camera: PermissionStatus.notRequested))
      ..afterAnswer = () => _report(camera: PermissionStatus.permanentlyDenied);
    final results = await pumpScreen(
      tester,
      VayuFeature.scanCode,
      alreadyExplained: true,
    );
    await tester.tap(find.text('Do it'));
    await tester.pumpAndSettle();

    // The tap on Scan was the context: the dialog came first, no sheet.
    expect(platform.requested, [PermissionGroup.camera]);
    expect(find.text('Camera is blocked'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Open settings'), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('Android 10 with Location off opens the Location page', (
    tester,
  ) async {
    platform = _FakePlatform(_report(location: SwitchState.off));
    final results = await pumpScreen(tester, VayuFeature.findPhones);
    await tester.tap(find.text('Do it'));
    await tester.pumpAndSettle();

    expect(find.text('Turn on Location'), findsOneWidget);
    expect(find.textContaining('Android 10'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Open Location settings'));
    await tester.pumpAndSettle();
    expect(platform.opened, [SettingsPage.location]);

    platform.report = _report();
    await comeBackFromSettings(tester);
    expect(results, [true]);
  });
}
