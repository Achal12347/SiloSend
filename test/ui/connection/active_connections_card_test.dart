import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/connection/active_connections_card.dart';

void main() {
  group('ActiveConnectionsCard Widget Tests', () {
    late LocalDeviceIdentity identityA;
    late LocalDeviceIdentity identityB;
    late LanConnectionServer serverB;
    late ConnectionManager managerA;
    late ConnectionManager managerB;
    late AppContainer containerA;

    setUp(() async {
      identityA = LocalDeviceIdentity.generate(
        displayName: 'Sender-Phone',
        platform: 'android',
      );
      identityB = LocalDeviceIdentity.generate(
        displayName: 'Receiver-Laptop',
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
      );
      await containerA.initialize();
    });

    tearDown(() async {
      containerA.dispose();
      await managerB.dispose();
      await serverB.dispose();
    });

    testWidgets('renders empty state when no connections are active', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ActiveConnectionsCard(container: containerA)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Active Connections'), findsOneWidget);
      expect(find.textContaining('No active peer connections'), findsOneWidget);
      expect(find.text('Disconnect'), findsNothing);
    });

    testWidgets('renders established session and allows user to disconnect', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ActiveConnectionsCard(container: containerA)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // Connect from containerA to serverB using real I/O inside runAsync
      String? sessionId;
      await tester.runAsync(() async {
        final sessionBFuture = managerB.onSessionEstablished.first;
        final sessionA = await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: serverB.boundPort,
        );
        await sessionBFuture;
        sessionId = sessionA.sessionId;
      });

      // Pump frames to render active session
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Receiver-Laptop'), findsOneWidget);
      expect(find.text('LAN'), findsWidgets);
      expect(find.text('1 Active'), findsOneWidget);
      expect(
        find.text('Transport link established (Phase 5 unauthenticated)'),
        findsOneWidget,
      );
      expect(find.text('Disconnect'), findsOneWidget);

      // Tap disconnect and await session closed event inside runAsync
      await tester.runAsync(() async {
        final closedFuture = managerA.onSessionClosed.first;
        await tester.tap(find.text('Disconnect'));
        await closedFuture;
      });
      await tester.pump(const Duration(milliseconds: 100));

      // Verify session is closed and active list is empty
      expect(containerA.activeSessions.isEmpty, isTrue);
      expect(managerA.getSession(sessionId!), isNull);
      expect(find.textContaining('No active peer connections'), findsOneWidget);
    });
  });
}
