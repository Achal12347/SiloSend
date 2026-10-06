import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/ble_connection_server.dart';
import 'package:vayu/core/contracts/transport_contract.dart';

void main() {
  group('BleConnectionServer Event Dispatch Tests', () {
    late StreamController<Map<String, dynamic>> eventController;
    late BleConnectionServer server;

    setUp(() async {
      eventController = StreamController<Map<String, dynamic>>.broadcast();
      server = BleConnectionServer(customEventStream: eventController.stream);
      await server.start();
    });

    tearDown(() async {
      await server.dispose();
      await eventController.close();
    });

    test(
      'dispatches incoming BLE GATT connection and handles data routing',
      () async {
        final connFuture = server.incomingConnections.first;

        // Emit connected event
        eventController.add({
          'type': 'connected',
          'connectionId': 'ble_server_11:22:33:44:55:66',
          'remoteAddress': '11:22:33:44:55:66',
          'mtu': 23,
        });

        final conn = await connFuture;
        expect(conn.connectionId, 'ble_server_11:22:33:44:55:66');
        expect(conn.remoteAddress, '11:22:33:44:55:66');
        expect(conn.currentMtu, 23);
        expect(conn.isConnected, isTrue);

        // Route data chunk
        final chunkFuture = conn.incomingBytes.first;
        eventController.add({
          'type': 'data',
          'connectionId': 'ble_server_11:22:33:44:55:66',
          'data': Uint8List.fromList([10, 20, 30]),
        });

        final receivedChunk = await chunkFuture;
        expect(receivedChunk, equals(Uint8List.fromList([10, 20, 30])));

        // MTU changed event
        eventController.add({
          'type': 'mtuChanged',
          'connectionId': 'ble_server_11:22:33:44:55:66',
          'mtu': 247,
        });
        await pumpEventQueue();
        expect(conn.currentMtu, 247);

        // Disconnected event
        final disconnectDone = conn.incomingBytes.isEmpty;
        eventController.add({
          'type': 'disconnected',
          'connectionId': 'ble_server_11:22:33:44:55:66',
          'reason': 'Peer link dropped',
        });
        await pumpEventQueue();

        expect(conn.state, ConnectionState.disconnected);
        expect(conn.disconnectReason, 'Peer link dropped');
        expect(await disconnectDone, isTrue);
      },
    );
  });
}
