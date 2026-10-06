import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/connection/ble_connection.dart';
import 'package:silosend_datasharing_app/core/connection/framed_transport_connection.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/domain/protocol/packet_type.dart';
import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';

class _TestBleAdapter implements BleTransportAdapter {
  final List<Uint8List> sentChunks = [];
  bool disconnected = false;
  bool connected = false;

  @override
  Future<void> connect(String address, {int mtu = 512}) async {
    connected = true;
  }

  @override
  Future<void> sendChunk(String connectionId, Uint8List chunk) async {
    sentChunks.add(chunk);
  }

  @override
  Future<void> disconnect(String connectionId) async {
    disconnected = true;
  }
}

void main() {
  group('BleConnection ATT-MTU Slicing & Transport Tests', () {
    late _TestBleAdapter adapter;
    late BleConnection connection;

    setUp(() {
      adapter = _TestBleAdapter();
      connection = BleConnection(
        connectionId: 'ble_test_123',
        remoteAddress: 'AA:BB:CC:DD:EE:FF',
        adapter: adapter,
      );
    });

    tearDown(() async {
      await connection.close();
    });

    test(
      'slices outgoing data into ATT-MTU safe chunks with default MTU 23',
      () async {
        expect(connection.currentMtu, 23);
        expect(connection.effectivePayloadSize, 20);

        // Send 50 bytes -> chunks of 20, 20, 10
        final data = Uint8List.fromList(List.generate(50, (i) => i));
        await connection.sendBytes(data);

        expect(adapter.sentChunks.length, 3);
        expect(adapter.sentChunks[0].length, 20);
        expect(adapter.sentChunks[1].length, 20);
        expect(adapter.sentChunks[2].length, 10);

        // Reassembly matches original
        final reassembled = Uint8List(50);
        int offset = 0;
        for (final chunk in adapter.sentChunks) {
          reassembled.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        expect(reassembled, equals(data));
      },
    );

    test('dynamically updates MTU when onMtuChanged fires', () async {
      // Negotiate MTU 512
      connection.handleMtuChanged(512);

      expect(connection.currentMtu, 512);
      expect(connection.effectivePayloadSize, 509);

      // Send 600 bytes -> chunks of 509, 91
      final data = Uint8List.fromList(List.generate(600, (i) => i % 256));
      await connection.sendBytes(data);

      expect(adapter.sentChunks.length, 2);
      expect(adapter.sentChunks[0].length, 509);
      expect(adapter.sentChunks[1].length, 91);
    });

    test('delivers incoming chunks through incomingBytes stream', () async {
      final receivedFuture = connection.incomingBytes.first;

      final chunk = Uint8List.fromList([1, 2, 3, 4, 5]);
      connection.handleIncomingBytes(chunk);

      final received = await receivedFuture;
      expect(received, equals(chunk));
    });

    test('reconstructs SiloSendPacket seamlessly when wrapped in FramedTransportConnection', () async {
      final framed = FramedTransportConnection(connection);

      // Create a test packet
      final sourceId = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final destId = Uint8List.fromList(List.generate(16, (i) => i + 17));
      final payload = Uint8List.fromList(
        List.generate(80, (i) => (i * 3) % 256),
      );

      final originalPacket = SiloSendPacket(
        packetType: PacketType.transferChunk,
        packetId: 101,
        sourceDeviceId: sourceId,
        destinationDeviceId: destId,
        payload: payload,
      );

      final packetBytes = originalPacket.toBytes();
      // Total packet size: 49 (header) + 80 (payload) + 4 (CRC32) = 133 bytes

      final packetFuture = framed.incomingPackets.first;

      // Simulate incoming BLE GATT reception in small 20-byte slices
      int offset = 0;
      while (offset < packetBytes.length) {
        final chunkSize = (packetBytes.length - offset).clamp(0, 20);
        final slice = packetBytes.sublist(offset, offset + chunkSize);
        connection.handleIncomingBytes(slice);
        offset += chunkSize;
      }

      final reconstructed = await packetFuture;
      expect(reconstructed.packetType, PacketType.transferChunk);
      expect(reconstructed.packetId, 101);
      expect(reconstructed.sourceDeviceId, equals(sourceId));
      expect(reconstructed.destinationDeviceId, equals(destId));
      expect(reconstructed.payload, equals(payload));
    });

    test('handles peer disconnection gracefully', () async {
      final streamDoneFuture = connection.incomingBytes.isEmpty;

      connection.handlePeerDisconnected('Remote GATT closed');

      expect(connection.state, ConnectionState.disconnected);
      expect(connection.isConnected, isFalse);
      expect(connection.disconnectReason, 'Remote GATT closed');
      expect(await streamDoneFuture, isTrue);
    });

    test(
      'close terminates adapter and marks connection disconnected',
      () async {
        await connection.close(reason: 'User disconnected');

        expect(adapter.disconnected, isTrue);
        expect(connection.state, ConnectionState.disconnected);
        expect(connection.disconnectReason, 'User disconnected');
      },
    );
  });
}
