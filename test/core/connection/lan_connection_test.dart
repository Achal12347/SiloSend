import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/framed_transport_connection.dart';
import 'package:vayu/core/connection/lan_connection.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';

void main() {
  group('LanConnection & LanConnectionServer Real TCP Socket Tests', () {
    late LanConnectionServer server;
    final devA = Uint8List.fromList(List.generate(16, (i) => i));
    final devB = Uint8List.fromList(List.generate(16, (i) => i + 10));

    setUp(() async {
      // Bind to dynamic ephemeral port (port 0) for safe isolated test execution
      server = LanConnectionServer(requestedPort: 0);
      await server.start();
    });

    tearDown(() async {
      await server.dispose();
    });

    test(
      'establishes real loopback TCP connection and exchanges framed packets',
      () async {
        final serverConnectionFuture = server.incomingConnections.first;

        final clientRaw = await LanConnection.connect(
          '127.0.0.1',
          server.boundPort,
        );
        final serverRaw = await serverConnectionFuture;

        expect(clientRaw.isConnected, isTrue);
        expect(serverRaw.isConnected, isTrue);
        expect(clientRaw.type, equals(TransportType.lan));

        final clientFramed = FramedTransportConnection(clientRaw);
        final serverFramed = FramedTransportConnection(serverRaw);

        // Client sends packet to server
        final testPacket = VayuPacket(
          packetType: PacketType.chatMessage,
          packetId: 555,
          sourceDeviceId: devA,
          destinationDeviceId: devB,
          payload: Uint8List.fromList(utf8.encode('Live TCP test message!')),
        );

        final serverReceivedPacketFuture = serverFramed.incomingPackets.first;
        await clientFramed.sendPacket(testPacket);

        final receivedPacket = await serverReceivedPacketFuture;
        expect(receivedPacket.packetId, equals(555));
        expect(receivedPacket.packetType, equals(PacketType.chatMessage));
        expect(
          utf8.decode(receivedPacket.payload),
          equals('Live TCP test message!'),
        );

        // Server responds back to client
        final replyPacket = VayuPacket(
          packetType: PacketType.chatDeliveryAck,
          packetId: 556,
          sourceDeviceId: devB,
          destinationDeviceId: devA,
          payload: Uint8List(0),
        );

        final clientReceivedPacketFuture = clientFramed.incomingPackets.first;
        await serverFramed.sendPacket(replyPacket);

        final clientReceived = await clientReceivedPacketFuture;
        expect(clientReceived.packetId, equals(556));
        expect(clientReceived.packetType, equals(PacketType.chatDeliveryAck));

        // Teardown
        await clientFramed.close();
        await serverFramed.close();

        expect(clientRaw.isConnected, isFalse);
      },
    );

    test('cleanly detects unexpected socket closure by peer', () async {
      final serverConnectionFuture = server.incomingConnections.first;

      final clientRaw = await LanConnection.connect(
        '127.0.0.1',
        server.boundPort,
      );
      final serverRaw = await serverConnectionFuture;

      expect(serverRaw.isConnected, isTrue);

      // Close client abruptly
      await clientRaw.close(reason: 'Abrupt close test');

      // Wait a moment for TCP FIN/RST packet propagation over loopback
      await Future.delayed(const Duration(milliseconds: 50));

      expect(serverRaw.isConnected, isFalse);
      await serverRaw.close();
    });

    test('sendBytes throws StateError when connection is closed', () async {
      final serverConnectionFuture = server.incomingConnections.first;

      final clientRaw = await LanConnection.connect(
        '127.0.0.1',
        server.boundPort,
      );
      final serverRaw = await serverConnectionFuture;

      await clientRaw.close(reason: 'Test closure');
      expect(
        () => clientRaw.sendBytes(Uint8List.fromList([1, 2, 3])),
        throwsStateError,
      );

      await serverRaw.close();
    });

    test('reports accurate link metrics baseline', () async {
      final serverConnectionFuture = server.incomingConnections.first;

      final clientRaw = await LanConnection.connect(
        '127.0.0.1',
        server.boundPort,
      );
      final serverRaw = await serverConnectionFuture;

      final metrics = clientRaw.currentMetrics;
      expect(metrics.latencyMs, equals(1));
      expect(metrics.rssi, equals(0));

      await clientRaw.close();
      await serverRaw.close();
    });
  });
}
