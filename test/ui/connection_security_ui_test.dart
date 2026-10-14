import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/security/trust_level.dart';
import 'package:vayu/ui/connection/active_connections_card.dart';

void main() {
  group('Connection Security UI & SAS Verification Tests', () {
    late LocalDeviceIdentity identityA;
    late LocalDeviceIdentity identityB;
    late LanConnectionServer serverB;
    late ConnectionManager managerA;
    late ConnectionManager managerB;
    late AppContainer containerA;
    late AppContainer containerB;

    setUp(() async {
      identityA = LocalDeviceIdentity.generate(
        displayName: 'Phone-Alice',
        platform: 'android',
      );
      identityB = LocalDeviceIdentity.generate(
        displayName: 'Laptop-Bob',
        platform: 'windows',
      );

      serverB = LanConnectionServer(requestedPort: 0);
      await serverB.start();

      managerA = ConnectionManager(
        localIdentity: identityA,
        handshakeTimeout: const Duration(seconds: 5),
        pingInterval: const Duration(hours: 1),
        inactivityTimeout: const Duration(hours: 1),
      );
      managerB = ConnectionManager(
        localIdentity: identityB,
        handshakeTimeout: const Duration(seconds: 5),
        pingInterval: const Duration(hours: 1),
        inactivityTimeout: const Duration(hours: 1),
      );
      managerB.registerLanServer(serverB);

      containerA = AppContainer.standard(
        storage: InMemoryIdentityStorage(identityA),
        connectionManager: managerA,
        secureKeyStore: InMemorySecureKeyStore(),
      );
      containerB = AppContainer.standard(
        storage: InMemoryIdentityStorage(identityB),
        connectionManager: managerB,
        secureKeyStore: InMemorySecureKeyStore(),
      );

      await containerA.initialize();
      await containerB.initialize();
    });

    tearDown(() async {
      containerA.dispose();
      containerB.dispose();
      await serverB.dispose();
    });

    testWidgets(
      'ActiveConnectionsCard renders AES-256-GCM badge and opens SAS dialog',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ActiveConnectionsCard(container: containerA)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        // 1. Establish connection from Alice (A) to Bob (B) over loopback TCP
        // Because containerA and containerB have auto-securing wired up,
        // the connection automatically elevates from SessionState.connected to SessionState.secured!
        await tester.runAsync(() async {
          final sessionBFuture = containerB.secureSessionsStream.first;
          final sessionAFuture = containerA.secureSessionsStream.first;
          await containerA.connectionManager.connectToLanPeer(
            remoteAddress: '127.0.0.1',
            remotePort: serverB.boundPort,
          );

          // Await secured session on both sides
          await Future.wait([sessionBFuture, sessionAFuture]);
        });

        // Pump to render updated secured connection card
        await tester.pumpAndSettle();

        // Verify truthful peer name and secured badges
        expect(find.text('Laptop-Bob'), findsOneWidget);
        expect(find.text('AES-256-GCM'), findsOneWidget);
        expect(
          find.text(TrustLevel.unverifiedTOFU.displayLabel),
          findsOneWidget,
        );
        expect(find.text('Verify SAS'), findsOneWidget);

        // 2. Tap 'Verify SAS' to open dialog
        await tester.tap(find.text('Verify SAS'));
        await tester.pumpAndSettle();

        // Verify dialog contents
        expect(find.text('Check the safety words'), findsOneWidget);
        expect(find.text('They match'), findsOneWidget);
        expect(find.text("They don't match"), findsOneWidget);
        // The fingerprint stays behind "Details".
        await tester.tap(find.text('Details'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Device fingerprint'), findsOneWidget);

        // 3. Confirm Match inside dialog
        await tester.runAsync(() async {
          await tester.tap(find.text('They match'));
        });
        await tester.pumpAndSettle();

        // Verify dialog is dismissed and trust level badge is now 'SAS Verified'
        expect(find.text('Check the safety words'), findsNothing);
        expect(find.text(TrustLevel.sasVerified.displayLabel), findsOneWidget);
      },
    );

    testWidgets('SAS dialog Mismatch / Abort disconnects the session', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ActiveConnectionsCard(container: containerA)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.runAsync(() async {
        final sessionBFuture = containerB.secureSessionsStream.first;
        final sessionAFuture = containerA.secureSessionsStream.first;
        await containerA.connectionManager.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: serverB.boundPort,
        );
        await Future.wait([sessionBFuture, sessionAFuture]);
      });

      await tester.pumpAndSettle();
      expect(find.text('Verify SAS'), findsOneWidget);

      // Open dialog
      await tester.tap(find.text('Verify SAS'));
      await tester.pumpAndSettle();

      // Tap 'Mismatch / Abort'
      await tester.runAsync(() async {
        final closedFuture = containerA.connectionManager.onSessionClosed.first;
        await tester.tap(find.text("They don't match"));
        await closedFuture;
      });
      await tester.pumpAndSettle();

      // Verify session is closed and active connections is empty
      expect(containerA.activeSessions.isEmpty, isTrue);
      expect(find.textContaining('No active peer connections'), findsOneWidget);
    });
  });
}
