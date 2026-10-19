import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/peer_picker_sheet.dart';

void main() {
  late AppContainer container;

  Future<List<DiscoveredPeer?>> open(WidgetTester tester) async {
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 9)),
            displayName: 'Tester',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
      );
      await container.initialize();
    });
    final picked = <DiscoveredPeer?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked.add(
                await pickNearbyPeer(
                  context,
                  container: container,
                  title: 'Send your card to',
                ),
              ),
              child: const Text('Pick'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    return picked;
  }

  tearDown(() => container.dispose());

  testWidgets('with nobody nearby it offers Scan QR instead of a dead end', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Send your card to'), findsOneWidget);
    expect(find.textContaining('No phones nearby yet'), findsOneWidget);
    expect(find.text('Scan QR'), findsOneWidget);
  });

  testWidgets('a nearby phone can be picked from the list', (tester) async {
    final picked = await open(tester);
    container.discoveryCoordinator.ingestPeerForTesting(
      DiscoveredPeer(
        deviceId: '33333333333333333333333333333333',
        displayName: 'Receiver-Phone',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan},
        rssi: -50,
        lastSeen: DateTime.now(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Scan QR'), findsOneWidget);
    await tester.tap(find.text('Receiver-Phone'));
    await tester.pumpAndSettle();
    expect(picked.single?.displayName, 'Receiver-Phone');
  });
}
