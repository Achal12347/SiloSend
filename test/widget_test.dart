import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/constants/app_constants.dart';
import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/identity/identity_storage.dart';
import 'package:silosend_datasharing_app/core/state/app_container.dart';
import 'package:silosend_datasharing_app/domain/identity/local_device_identity.dart';
import 'package:silosend_datasharing_app/main.dart';
import 'package:silosend_datasharing_app/platform/system_platform_service.dart';

void main() {
  testWidgets(
    'SiloSendApp mounts, initializes real identity, and renders truthful discovery & connection state',
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
      );

      await tester.pumpWidget(SiloSendApp(container: container));
      await tester.pumpAndSettle();

      // Verify app name and subtitle
      expect(find.text(AppConstants.appName), findsWidgets);
      expect(find.text('Offline Device-to-Device Sharing'), findsOneWidget);

      // Verify real local device identity
      expect(find.text('Test-Device-Alpha'), findsOneWidget);
      expect(find.text('42424242...4242'), findsOneWidget);
      expect(find.text('v1'), findsOneWidget);

      // Verify device discovery card exists with Scan Nearby button
      expect(find.text('Nearby Device Discovery'), findsOneWidget);
      expect(find.text('Scan Nearby'), findsOneWidget);

      // Verify active connections card exists
      expect(find.text('Active Connections'), findsOneWidget);
      expect(find.textContaining('No active peer connections'), findsOneWidget);

      // Verify application lifecycle
      expect(find.text('Foreground (Active)'), findsOneWidget);

      // Verify truthful capabilities without fake claims
      expect(find.text('Unknown (Not Probed)'), findsNWidgets(3));

      // Verify honest status confirmation
      expect(
        find.text('Truthful Discovery & Connection Foundation Active'),
        findsOneWidget,
      );

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

      // Verify peer is displayed with Unverified Claim badge and Connect button
      expect(find.text('Remote-Pixel'), findsOneWidget);
      expect(find.text('Unverified Claim'), findsOneWidget);
      expect(find.text('LAN'), findsWidgets);
      expect(find.text('BLE'), findsWidgets);
      expect(find.text('Connect'), findsOneWidget);

      // Tap pairing button in AppBar to open out-of-band pairing dialog
      await tester.tap(find.byIcon(Icons.qr_code_2_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Out-of-Band Pairing'), findsOneWidget);
      expect(find.text('Local Pairing URI'), findsOneWidget);
      expect(find.text('Connect Out-of-Band'), findsOneWidget);

      // Close pairing dialog
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Out-of-Band Pairing'), findsNothing);

      container.dispose();
    },
  );
}
