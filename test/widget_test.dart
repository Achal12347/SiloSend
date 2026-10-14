import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/main.dart';
import 'package:vayu/platform/system_platform_service.dart';

void main() {
  testWidgets(
    'VayuApp mounts, initializes real identity, and renders truthful discovery & connection state',
    (WidgetTester tester) async {
      final identity = LocalDeviceIdentity(
        deviceId: Uint8List.fromList(List<int>.filled(16, 0x42)),
        displayName: 'Test-Device-Alpha',
        createdAt: DateTime.now(),
        protocolVersion: 1,
        platform: 'android',
      );

      final storage = InMemoryIdentityStorage(identity);
      final container = AppContainer.standard(
        storage: storage,
        platformService: SystemPlatformService(platformNameOverride: 'android'),
        // Returning user: onboarding already finished.
        settingsStorage: InMemorySettingsStorage(
          const UserSettings(
            onboardingVersion: UserSettings.currentOnboardingVersion,
          ),
        ),
      );

      await container.initialize();
      await tester.pumpWidget(VayuApp(container: container));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify app name in AppBar
      expect(find.text(AppConstants.appName), findsWidgets);

      // Nearby section with an honest idle state and a Search action
      expect(find.text('Nearby devices'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);

      // No live sessions: the connections card stays hidden instead of
      // showing protocol vocabulary.
      expect(find.text('Active Connections'), findsNothing);

      // Ingest a discovered peer into coordinator to verify truthful UI card rendering
      container.discoveryCoordinator.ingestPeerForTesting(
        DiscoveredPeer(
          deviceId: '99999999999999999999999999999999',
          displayName: 'Remote-Pixel',
          transportType: TransportType.lan,
          availableTransports: {TransportType.lan, TransportType.ble},
          rssi: -60,
          endpointAddress: '192.168.1.100:53531',
          lastSeen: DateTime.now(),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      // Peer row with real reachability, a send action, and connect in its menu
      expect(find.text('Remote-Pixel'), findsOneWidget);
      expect(find.text('New device'), findsOneWidget);
      expect(find.text('Send files'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);

      // The pairing button opens the pairing screen in "Show code" mode
      await tester.tap(find.byTooltip('Pair with QR or NFC'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Pair a phone'), findsOneWidget);
      expect(find.text('Show code'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Pair a phone'), findsNothing);

      // Real local identity, without raw IDs on the home screen
      await tester.scrollUntilVisible(find.text('Your device'), 200);
      expect(find.text('Test-Device-Alpha'), findsOneWidget);
      expect(find.text('42424242...4242'), findsNothing);

      container.dispose();
    },
  );
}
