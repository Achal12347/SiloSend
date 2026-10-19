import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/shell/app_shell.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/readable_width.dart';

import 'home/vayu_home_page_test.dart' show MockDiscoveryService;

/// The main screens on a phone, a phone held sideways and a tablet.
void main() {
  late AppContainer container;

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 8)),
            displayName: 'Tester',
            platform: 'android',
            createdAt: DateTime(2026),
          ),
        ),
        discoveryCoordinator: DiscoveryCoordinator(
          services: [MockDiscoveryService(TransportType.lan)],
        ),
        settingsStorage: InMemorySettingsStorage(
          const UserSettings(
            onboardingVersion: UserSettings.currentOnboardingVersion,
            profileName: 'Tester',
          ),
        ),
      );
      await container.initialize();
    });
    addTearDown(container.dispose);
    await tester.pumpWidget(
      AppScope(
        container: container,
        child: MaterialApp(
          theme: VayuTheme.light(),
          builder: (context, child) => ReadableWidth(child: child!),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 9));
  }

  Future<void> visitTabs(WidgetTester tester) async {
    for (final tab in ['Chats', 'Host & Client', 'Home']) {
      await tester.tap(find.text(tab).last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    }
  }

  testWidgets('phone: bottom bar, full width', (tester) async {
    await pumpAt(tester, const Size(360, 780));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    await visitTabs(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone sideways: side rail, nothing overflows', (tester) async {
    await pumpAt(tester, const Size(780, 360));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await visitTabs(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tablet: side rail and a readable column, not stretched', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800));
    expect(find.byType(NavigationRail), findsOneWidget);
    final shell = tester.getSize(find.byType(AppShell));
    expect(shell.width, ReadableWidth.maxWidth);
    await visitTabs(tester);
    await tester.pumpWidget(const SizedBox());
  });
}
