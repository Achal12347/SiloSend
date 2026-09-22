import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/connection/framed_transport_connection.dart';
import 'package:silosend_datasharing_app/core/connection/packet_framing.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/domain/protocol/packet_type.dart';
import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';

class _MockTransportConnection implements TransportConnection {
  @override
  final String connectionId = 'mock_conn_1';
  @override
  final TransportType type = TransportType.lan;
  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();

  ConnectionState _state = ConnectionState.connected;
  String? _disconnectReason;
  final List<Uint8List> sentBytesLog = [];

  @override
  ConnectionState get state => _state;

  @override
  bool get isConnected => _state == ConnectionState.connected;

  @override
  String? get remoteAddress => '192.168.1.100';

  @override
  int? get remotePort => 53531;

  @override
  String? get disconnectReason => _disconnectReason;

  @override
  Stream<Uint8List> get incomingBytes => _incomingController.stream;

  void emitBytes(Uint8List bytes) => _incomingController.add(bytes);

  @override
  Future<void> sendBytes(Uint8List data) async {
    sentBytesLog.add(data);
  }

  @override
  Future<void> close({String? reason}) async {
    _state = ConnectionState.disconnected;
    _disconnectReason = reason;
    await _incomingController.close();
  }

  @override
  LinkMetrics get currentMetrics => LinkMetrics.zero;
}

void main() {
  group('PacketStreamTransformer Tests', () {
    final devA = Uint8List.fromList(List.generate(16, (i) => i));
    final devB = Uint8List.fromList(List.generate(16, (i) => i + 10));

    test('correctly frames a single complete packet', () async {
      final packet = SiloSendPacket(
        packetType: PacketType.chatMessage,
        packetId: 101,
        sourceDeviceId: devA,
        destinationDeviceId: devB,
        payload: Uint8List.fromList(utf8.encode('Hello SiloSend!')),
      );

      final controller = StreamController<Uint8List>();
      final framedStream = controller.stream.transform(
        PacketStreamTransformer(),
      );

      final results = <SiloSendPacket>[];
      final sub = framedStream.listen(results.add);

      controller.add(packet.toBytes());
      await pumpEventQueue();

      expect(results.length, equals(1));
      expect(results.first.packetId, equals(101));
      expect(utf8.decode(results.first.payload), equals('Hello SiloSend!'));

      await sub.cancel();
      await controller.close();
    });

    test(
      'reassembles a packet fragmented across multiple byte chunks',
      () async {
        final packet = SiloSendPacket(
          packetType: PacketType.handshakeInit,
          packetId: 202,
          sourceDeviceId: devA,
          destinationDeviceId: devB,
          payload: Uint8List.fromList(
            utf8.encode('Fragmented handshake payload'),
          ),
        );

        final bytes = packet.toBytes();
        final controller = StreamController<Uint8List>();
        final framedStream = controller.stream.transform(
          PacketStreamTransformer(),
        );

        final results = <SiloSendPacket>[];
        final sub = framedStream.listen(results.add);

        // Split into 3 arbitrary chunks: 10 bytes, 25 bytes, remaining
        controller.add(Uint8List.sublistView(bytes, 0, 10));
        await pumpEventQueue();
        expect(results, isEmpty); // Incomplete

        controller.add(Uint8List.sublistView(bytes, 10, 35));
        await pumpEventQueue();
        expect(results, isEmpty); // Still incomplete

        controller.add(Uint8List.sublistView(bytes, 35));
        await pumpEventQueue();

        expect(results.length, equals(1));
        expect(results.first.packetId, equals(202));
        expect(
          utf8.decode(results.first.payload),
          equals('Fragmented handshake payload'),
        );

        await sub.cancel();
        await controller.close();
      },
    );

    test(
      'extracts multiple packets delivered in a single byte chunk',
      () async {
        final p1 = SiloSendPacket(
          packetType: PacketType.ping,
          packetId: 1,
          sourceDeviceId: devA,
          destinationDeviceId: devB,
          payload: Uint8List(0),
        );
        final p2 = SiloSendPacket(
          packetType: PacketType.pong,
          packetId: 2,
          sourceDeviceId: devB,
          destinationDeviceId: devA,
          payload: Uint8List(0),
        );

        final combined = Uint8List.fromList([...p1.toBytes(), ...p2.toBytes()]);

        final controller = StreamController<Uint8List>();
        final framedStream = controller.stream.transform(
          PacketStreamTransformer(),
        );

        final results = <SiloSendPacket>[];
        final sub = framedStream.listen(results.add);

        controller.add(combined);
        await pumpEventQueue();

        expect(results.length, equals(2));
        expect(results[0].packetType, equals(PacketType.ping));
        expect(results[1].packetType, equals(PacketType.pong));

        await sub.cancel();
        await controller.close();
      },
    );

    test('discards leading garbage bytes preceding magic bytes', () async {
      final validPacket = SiloSendPacket(
        packetType: PacketType.ping,
        packetId: 777,
        sourceDeviceId: devA,
        destinationDeviceId: devB,
        payload: Uint8List(0),
      );

      final garbage = Uint8List.fromList([
        0xAA,
        0xBB,
        0xCC,
        0xDD,
        0x53,
      ]); // partial/bad
      final combined = Uint8List.fromList([
        ...garbage,
        ...validPacket.toBytes(),
      ]);

      final controller = StreamController<Uint8List>();
      final framedStream = controller.stream.transform(
        PacketStreamTransformer(),
      );

      final results = <SiloSendPacket>[];
      final sub = framedStream.listen(results.add);

      controller.add(combined);
      await pumpEventQueue();

      expect(results.length, equals(1));
      expect(results.first.packetId, equals(777));

      await sub.cancel();
      await controller.close();
    });
  });

  group('FramedTransportConnection Tests', () {
    final devA = Uint8List.fromList(List.generate(16, (i) => i));
    final devB = Uint8List.fromList(List.generate(16, (i) => i + 5));

    test('wraps raw TransportConnection and provides incoming packets and sendPacket', () async {
      final mock = _MockTransportConnection();
      final framed = FramedTransportConnection(mock);

      expect(framed.connectionId, equals('mock_conn_1'));
      expect(framed.type, equals(TransportType.lan));
      expect(framed.isConnected, isTrue);
      expect(framed.remoteAddress, equals('192.168.1.100'));
      expect(framed.remotePort, equals(53531));

      final receivedPackets = <SiloSendPacket>[];
      final sub = framed.incomingPackets.listen(receivedPackets.add);

      final packetIn = SiloSendPacket(
        packetType: PacketType.ping,
        packetId: 999,
        sourceDeviceId: devA,
        destinationDeviceId: devB,
        payload: Uint8List(0),
      );

      mock.emitBytes(packetIn.toBytes());
      await pumpEventQueue();

      expect(receivedPackets.length, equals(1));
      expect(receivedPackets.first.packetId, equals(999));

      // Test sendPacket
      final packetOut = SiloSendPacket(
        packetType: PacketType.pong,
        packetId: 1000,
        sourceDeviceId: devB,
        destinationDeviceId: devA,
        payload: Uint8List(0),
      );

      await framed.sendPacket(packetOut);
      expect(mock.sentBytesLog.length, equals(1));
      expect(mock.sentBytesLog.first, equals(packetOut.toBytes()));

      // Test close
      await framed.close(reason: 'Test complete');
      expect(mock.isConnected, isFalse);
      expect(mock.disconnectReason, equals('Test complete'));

      await sub.cancel();
    });
  });
}
