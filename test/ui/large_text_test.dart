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
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/domain/host/host_payloads.dart';
import 'package:vayu/ui/card/received_cards_page.dart';
import 'package:vayu/ui/chats/chats_page.dart';
import 'package:vayu/ui/chats/conversation_page.dart';
import 'package:vayu/ui/diagnostics/diagnostics_page.dart';
import 'package:vayu/ui/host/host_client_page.dart';
import 'package:vayu/ui/settings/settings_page.dart' as settings;
import 'package:vayu/ui/transfer/transfer_history_page.dart';
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
            baselinePermissionsAsked: true,
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

  /// [page] alone at 2x text, inside the app scope the tabs read.
  Future<void> show(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: VayuTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: page,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Scrolls through every list on screen, so overflow anywhere shows.
  Future<void> scrollAll(WidgetTester tester) async {
    for (final s in find.byType(Scrollable).evaluate().toList()) {
      final finder = find.byWidget(s.widget);
      for (var i = 0; i < 8; i++) {
        await tester.drag(finder, const Offset(0, -300), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  }

  testWidgets('Settings (with the relay switch) at 2x text', (tester) async {
    await pump(tester, const SizedBox());
    await show(tester, settings.SettingsPage(container: container));
    await tester.scrollUntilVisible(
      find.text('Help nearby phones connect'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Help nearby phones connect'), findsOneWidget);
    await scrollAll(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('History at 2x text', (tester) async {
    await pump(tester, const SizedBox());
    await show(tester, TransferHistoryPage(container: container));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chats and a conversation with files at 2x text', (tester) async {
    await pump(tester, const SizedBox());
    await show(tester, const ChatsPage());
    expect(tester.takeException(), isNull);
    await show(
      tester,
      ConversationPage(
        container: container,
        peerDeviceId: 'ab' * 16,
        peerName: 'A friend with quite a long phone name',
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Host & Client: choosing access and hosting privately at 2x '
      'text', (tester) async {
    await pump(tester, const SizedBox());
    await show(tester, const HostClientPage());
    await scrollAll(tester);
    expect(find.text('Private (PIN)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    container.hostService.startHosting('A long share name for testing', [
      const SelectedDocument(identifier: '/x', name: 'a.bin', sizeBytes: 10),
    ], access: HostAccess.private);
    await tester.pump(const Duration(milliseconds: 300));
    await scrollAll(tester);
    expect(find.text('PIN for your share'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(container.hostService.stopHosting);
  });

  testWidgets('Diagnostics at 2x text', (tester) async {
    await pump(tester, const SizedBox());
    await show(tester, DiagnosticsPage(container: container));
    await scrollAll(tester);
    expect(tester.takeException(), isNull);
  });
}
