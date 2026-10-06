import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/platform/system_platform_service.dart';
import 'package:vayu/ui/transfer/peer_selection_sheet.dart';

void main() {
  testWidgets(
    'PeerSelectionSheet renders document info and live discovered peers',
    (WidgetTester tester) async {
      final identity = LocalDeviceIdentity(
        deviceId: Uint8List.fromList(List<int>.filled(16, 0x11)),
        displayName: 'Test-Sender',
        createdAt: DateTime.now(),
        protocolVersion: 1,
        platform: 'android',
      );

      final container = AppContainer.standard(
        storage: InMemoryIdentityStorage(identity),
        platformService: SystemPlatformService(platformNameOverride: 'android'),
      );
      await container.initialize();

      const doc = SelectedDocument(
        identifier: 'content://media/external/files/101',
        name: 'report.pdf',
        sizeBytes: 1048576, // 1.0 MB
        mimeType: 'application/pdf',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => PeerSelectionSheet.show(
                  context,
                  document: doc,
                  container: container,
                ),
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );

      // Open sheet
      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      // Verify document summary is rendered truthfully
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('1.0 MB'), findsOneWidget);
      expect(find.text('Send To Nearby Device'), findsOneWidget);

      // Initially no peers -> shows empty searching state
      expect(
        find.text('Looking for nearby Vayu devices...'),
        findsOneWidget,
      );

      // Ingest remote peer
      container.discoveryCoordinator.ingestPeerForTesting(
        DiscoveredPeer(
          deviceId: '22222222222222222222222222222222',
          displayName: 'Receiver-Phone',
          transportType: TransportType.lan,
          availableTransports: {TransportType.lan, TransportType.ble},
          rssi: -50,
          lastSeen: DateTime.now(),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      // Peer appears with name and transport badges
      expect(find.text('Receiver-Phone'), findsOneWidget);
      expect(find.text('Wi-Fi'), findsOneWidget);
      expect(find.text('Bluetooth'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);

      await container.stopDiscoveryAndAdvertising();
      container.dispose();
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'PeerSelectionSheet renders batch summary for multiple documents',
    (WidgetTester tester) async {
      final identity = LocalDeviceIdentity(
        deviceId: Uint8List.fromList(List<int>.filled(16, 0x11)),
        displayName: 'Test-Sender',
        createdAt: DateTime.now(),
        protocolVersion: 1,
        platform: 'android',
      );

      final container = AppContainer.standard(
        storage: InMemoryIdentityStorage(identity),
        platformService: SystemPlatformService(platformNameOverride: 'android'),
      );
      await container.initialize();

      const docs = [
        SelectedDocument(
          identifier: 'content://media/external/files/101',
          name: 'photo1.jpg',
          sizeBytes: 1048576, // 1.0 MB
        ),
        SelectedDocument(
          identifier: 'content://media/external/files/102',
          name: 'photo2.jpg',
          sizeBytes: 2097152, // 2.0 MB
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => PeerSelectionSheet.show(
                  context,
                  documents: docs,
                  container: container,
                ),
                child: const Text('Open Batch Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Batch Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('2 files selected'), findsOneWidget);
      expect(find.text('3.0 MB total • Batch transfer'), findsOneWidget);

      await container.stopDiscoveryAndAdvertising();
      container.dispose();
      await tester.pump(const Duration(milliseconds: 100));
    },
  );
}
