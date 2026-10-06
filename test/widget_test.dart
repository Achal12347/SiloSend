import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
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
      );

      await container.initialize();
      await tester.pumpWidget(VayuApp(container: container));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify app name in AppBar
      expect(find.text(AppConstants.appName), findsWidgets);

      // Verify real local device identity card
      expect(find.text('Your Device'), findsOneWidget);
      expect(find.text('Test-Device-Alpha'), findsOneWidget);
      expect(find.text('42424242...4242'), findsOneWidget);

      // Verify nearby devices section exists with Scan Nearby button
      expect(find.text('Nearby Devices'), findsOneWidget);
      expect(find.text('Scan Nearby'), findsOneWidget);

      // Verify active connections card exists
      expect(find.text('Active Connections'), findsOneWidget);
      expect(find.textContaining('No active peer connections'), findsOneWidget);

      // Verify architecture confirmation banner
      expect(
        find.text('End-to-End Encrypted (AES-256-GCM) • Offline Direct'),
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

      // Verify peer is displayed with action buttons
      expect(find.text('Remote-Pixel'), findsOneWidget);
      expect(find.text('LAN'), findsWidgets);
      expect(find.text('BLE'), findsWidgets);
      expect(find.text('Send File'), findsNWidgets(2));
      expect(find.text('Connect'), findsOneWidget);

      // Tap pairing button in AppBar to open out-of-band pairing dialog
      await tester.tap(find.byIcon(Icons.qr_code_2_rounded));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Out-of-Band Pairing'), findsOneWidget);
      expect(find.text('Local Pairing URI'), findsOneWidget);
      expect(find.text('Connect Out-of-Band'), findsOneWidget);

      // Close pairing dialog
      await tester.tap(find.text('Close'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Out-of-Band Pairing'), findsNothing);

      container.dispose();
    },
  );
}
