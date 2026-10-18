import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contacts/received_cards.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/main.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';
import 'package:vayu/ui/card/received_cards_page.dart';
import 'package:vayu/ui/settings/permissions_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

/// Screens stay usable with the phone's largest text: nothing overflows on a
/// small phone at twice the normal text size.
class _Platform extends PlatformService {
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
  Future<PermissionReport> permissionReport() async => const PermissionReport(
    permissions: {
      PermissionGroup.nearby: PermissionStatus.permanentlyDenied,
      PermissionGroup.directWifi: PermissionStatus.denied,
      PermissionGroup.camera: PermissionStatus.notRequested,
      PermissionGroup.notifications: PermissionStatus.granted,
      PermissionGroup.storage: PermissionStatus.denied,
    },
    bluetooth: SwitchState.off,
    wifi: SwitchState.off,
    location: SwitchState.off,
    nfc: SwitchState.off,
    battery: SwitchState.off,
    sdkVersion: 29,
  );
}

void main() {
  late AppContainer container;

  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
        platformService: _Platform(),
      );
      await container.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() => container.dispose());

  testWidgets('Permissions & settings at 2x text', (tester) async {
    await pump(tester, const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: PermissionsPage(container: container),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Location'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Received cards at 2x text', (tester) async {
    await pump(tester, const SizedBox());
    await tester.runAsync(() async {
      await container.receivedCards!.addBytes(
        Uint8List.fromList(
          utf8.encode(
            'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Anantha Krishnan Venkataraman\r\nORG:A rather long company name Private Limited\r\nEND:VCARD\r\n',
          ),
        ),
        via: ReceivedVia.tap,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ReceivedCardsPage(container: container),
      ),
    );
    // Card faces are read from disk.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.text('Anantha Krishnan Venkataraman'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home at 2x text', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 6)),
            displayName: 'Tester',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
        platformService: _Platform(),
        settingsStorage: InMemorySettingsStorage(
          const UserSettings(
            onboardingVersion: UserSettings.currentOnboardingVersion,
          ),
        ),
      );
      await container.initialize();
    });
    await tester.pumpWidget(VayuApp(container: container));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.scrollUntilVisible(
      find.text('Receive'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Receive'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
