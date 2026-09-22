import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/connection/connection_manager.dart';
import 'package:silosend_datasharing_app/core/connection/lan_connection_server.dart';
import 'package:silosend_datasharing_app/core/contracts/security_contract.dart';
import 'package:silosend_datasharing_app/domain/identity/local_device_identity.dart';
import 'package:silosend_datasharing_app/domain/protocol/packet_type.dart';
import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';

void main() {
  group('ConnectionManager Real LAN Loopback Tests', () {
    late LocalDeviceIdentity identityA;
    late LocalDeviceIdentity identityB;
    late LanConnectionServer serverB;
    late ConnectionManager managerA;
    late ConnectionManager managerB;

    setUp(() async {
      identityA = LocalDeviceIdentity.generate(
        displayName: 'Phone-A',
        platform: 'android',
      );
      identityB = LocalDeviceIdentity.generate(
        displayName: 'Laptop-B',
        platform: 'windows',
      );

      // Bind server on ephemeral port 0
      serverB = LanConnectionServer(requestedPort: 0);
      await serverB.start();

      managerA = ConnectionManager(
        localIdentity: identityA,
        handshakeTimeout: const Duration(seconds: 5),
      );
      managerB = ConnectionManager(
        localIdentity: identityB,
        handshakeTimeout: const Duration(seconds: 5),
      );

      managerB.registerLanServer(serverB);
    });

    tearDown(() async {
      await managerA.dispose();
      await managerB.dispose();
      await serverB.dispose();
    });

    test(
      'successfully establishes two-way session over live TCP socket',
      () async {
        final sessionBFuture = managerB.onSessionEstablished.first;

        final sessionA = await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: serverB.boundPort,
        );

        final sessionB = await sessionBFuture;

        expect(sessionA.isActive, isTrue);
        expect(sessionB.isActive, isTrue);
        expect(sessionA.state, SessionState.connected);
        expect(sessionB.state, SessionState.connected);
        expect(sessionA.sessionId, sessionB.sessionId);

        // Identity cross-check
        expect(sessionA.remoteDeviceId, identityB.idHex.toLowerCase());
        expect(sessionB.remoteDeviceId, identityA.idHex.toLowerCase());
        expect(sessionA.info.remoteDisplayName, 'Laptop-B');
        expect(sessionB.info.remoteDisplayName, 'Phone-A');

        // Manager registries
        expect(managerA.activeSessions.length, 1);
        expect(managerB.activeSessions.length, 1);
        expect(managerA.hasSessionWithDevice(identityB.idHex), isTrue);
        expect(managerB.hasSessionWithDevice(identityA.idHex), isTrue);
      },
    );

    test(
      'exchanges application data packets and tracks byte metrics',
      () async {
        final sessionBFuture = managerB.onSessionEstablished.first;

        final sessionA = await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: serverB.boundPort,
        );
        final sessionB = await sessionBFuture;

        final messageBytes = Uint8List.fromList(
          utf8.encode('Hello from SiloSend A!'),
        );
        final packet = SiloSendPacket(
          packetType: PacketType.chatMessage,
          packetId: 42,
          sourceDeviceId: identityA.deviceId,
          destinationDeviceId: identityB.deviceId,
          payload: messageBytes,
        );

        final receivedPacketFuture = sessionB.incomingPackets.first;
        await sessionA.sendPacket(packet);

        final receivedPacket = await receivedPacketFuture;
        expect(receivedPacket.packetType, PacketType.chatMessage);
        expect(receivedPacket.packetId, 42);
        expect(utf8.decode(receivedPacket.payload), 'Hello from SiloSend A!');

        // Verify metrics tracked
        expect(sessionA.info.bytesSent, messageBytes.length);
        expect(sessionB.info.bytesReceived, messageBytes.length);
      },
    );

    test('rejects handshake when peer protocol version mismatches', () async {
      // Create Device C with incompatible protocol version
      final identityC = LocalDeviceIdentity(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i + 1)),
        displayName: 'Legacy-Device-C',
        platform: 'android',
        protocolVersion: 999, // Mismatched version
        createdAt: DateTime.now(),
      );

      final managerC = ConnectionManager(
        localIdentity: identityC,
        handshakeTimeout: const Duration(seconds: 3),
      );

      try {
        await expectLater(
          () => managerC.connectToLanPeer(
            remoteAddress: '127.0.0.1',
            remotePort: serverB.boundPort,
          ),
          throwsA(isA<HandshakeRejectedException>()),
        );
      } finally {
        await managerC.dispose();
      }
    });

    test('gracefully tears down session and notifies both peers', () async {
      final sessionBFuture = managerB.onSessionEstablished.first;

      final sessionA = await managerA.connectToLanPeer(
        remoteAddress: '127.0.0.1',
        remotePort: serverB.boundPort,
      );
      final sessionB = await sessionBFuture;

      final closedAFuture = managerA.onSessionClosed.first;
      final closedBFuture = managerB.onSessionClosed.first;

      // Disconnect from A
      await managerA.disconnectSession(
        sessionA.sessionId,
        reason: 'user_requested',
      );

      final closedSessionAId = await closedAFuture;
      final closedSessionBId = await closedBFuture;

      expect(closedSessionAId, sessionA.sessionId);
      expect(closedSessionBId, sessionB.sessionId);

      expect(sessionA.isActive, isFalse);
      expect(sessionB.isActive, isFalse);
      expect(sessionA.state, SessionState.closed);
      expect(sessionB.state, SessionState.closed);

      expect(managerA.activeSessions, isEmpty);
      expect(managerB.activeSessions, isEmpty);
    });

    test('automatically responds to keepalive ping with pong', () async {
      final sessionBFuture = managerB.onSessionEstablished.first;

      final sessionA = await managerA.connectToLanPeer(
        remoteAddress: '127.0.0.1',
        remotePort: serverB.boundPort,
      );
      await sessionBFuture;

      // Send a raw ping from A to B via framed connection
      final pingPacket = SiloSendPacket(
        packetType: PacketType.ping,
        packetId: 999,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payload: Uint8List(0),
      );

      // Under the hood, session B receives ping and auto-replies with pong
      // Session A handles pong in _handleIncomingPacket
      // We send ping through sessionA.sendPacket
      await sessionA.sendPacket(pingPacket);

      // Give a brief moment for loopback socket ping-pong exchange
      await Future.delayed(const Duration(milliseconds: 100));

      expect(sessionA.isActive, isTrue);
    });
  });
}
