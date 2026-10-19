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
import 'package:vayu/ui/chats/chats_page.dart';
import 'package:vayu/ui/chats/conversation_page.dart';
import 'package:vayu/ui/home/vayu_home_page.dart';
import 'package:vayu/ui/host/host_client_page.dart';
import 'package:vayu/ui/security/trusted_devices_page.dart';
import 'package:vayu/ui/settings/settings_page.dart' as settings;
import 'package:vayu/ui/settings/your_data_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/transfer_history_page.dart';

import 'home/vayu_home_page_test.dart' show MockDiscoveryService;

/// Flutter's accessibility guidelines on the main screens, light and dark:
/// text contrast (WCAG 4.5:1, 3:1 for large text), tap targets of at least
/// 48 x 48 (Android), and every tappable thing labelled for screen readers.
void main() {
  late AppContainer container;

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 7)),
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
  }

  final screens = <String, Widget Function()>{
    'Home': () => const VayuHomePage(),
    'Chats': () => const ChatsPage(),
    'Host & Client': () => const HostClientPage(),
    'Settings': () => settings.SettingsPage(container: container),
    'History': () => TransferHistoryPage(container: container),
    'Trusted devices': () => TrustedDevicesPage(container: container),
    'Your data': () => YourDataPage(container: container),
    'Conversation': () => ConversationPage(
      container: container,
      peerDeviceId: 'ab' * 16,
      peerName: 'Ana',
    ),
  };

  for (final dark in [false, true]) {
    for (final MapEntry(key: name, value: build) in screens.entries) {
      testWidgets('$name (${dark ? 'dark' : 'light'}) meets the '
          'accessibility guidelines', (tester) async {
        final semantics = tester.ensureSemantics();
        await start(tester);
        await tester.pumpWidget(
          AppScope(
            container: container,
            child: MaterialApp(
              theme: VayuTheme.light(),
              darkTheme: VayuTheme.dark(),
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              home: build(),
            ),
          ),
        );
        // Animations finish, nothing keeps scheduling frames forever.
        await tester.pump(const Duration(seconds: 9));
        Future<void> check() async {
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        }

        await check();
        // Long screens: check what scrolls into view too.
        final lists = find.byType(Scrollable);
        if (lists.evaluate().isNotEmpty) {
          for (var i = 0; i < 4; i++) {
            await tester.drag(
              lists.first,
              const Offset(0, -600),
              warnIfMissed: false,
            );
            await tester.pump(const Duration(milliseconds: 300));
            await check();
          }
        }
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
      });
    }
  }
}
