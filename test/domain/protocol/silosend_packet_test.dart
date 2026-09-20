import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/domain/protocol/packet_type.dart';
import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';

void main() {
  group('SiloSendPacket Tests', () {
    late Uint8List sourceId;
    late Uint8List destId;
    late Uint8List samplePayload;

    setUp(() {
      sourceId = Uint8List.fromList(List.generate(16, (i) => i + 1));
      destId = Uint8List.fromList(List.generate(16, (i) => 200 - i));
      samplePayload = Uint8List.fromList(utf8.encode('Hello SiloSend'));
    });

    test('encodes and decodes packet correctly (roundtrip)', () {
      final packet = SiloSendPacket(
        packetType: PacketType.chatMessage,
        packetId: 1001,
        sourceDeviceId: sourceId,
        destinationDeviceId: destId,
        ttl: 4,
        payload: samplePayload,
      );

      final encoded = packet.toBytes();
      expect(
        encoded.length,
        equals(SiloSendPacket.headerSize + samplePayload.length + 4),
      );

      final decoded = SiloSendPacket.fromBytes(encoded);
      expect(decoded.version, equals(SiloSendPacket.currentProtocolVersion));
      expect(decoded.packetType, equals(PacketType.chatMessage));
      expect(decoded.packetId, equals(1001));
      expect(decoded.sourceDeviceId, equals(sourceId));
      expect(decoded.destinationDeviceId, equals(destId));
      expect(decoded.ttl, equals(4));
      expect(decoded.payload, equals(samplePayload));
    });

    test('supports empty payload frames (e.g. Ping/Pong/Acks)', () {
      final ackPacket = SiloSendPacket(
        packetType: PacketType.ping,
        packetId: 42,
        sourceDeviceId: sourceId,
        destinationDeviceId: destId,
        payload: Uint8List(0),
      );

      final encoded = ackPacket.toBytes();
      expect(encoded.length, equals(SiloSendPacket.minPacketSize));

      final decoded = SiloSendPacket.fromBytes(encoded);
      expect(decoded.packetType, equals(PacketType.ping));
      expect(decoded.payload.length, equals(0));
    });

    test('rejects packet with invalid magic bytes', () {
      final packet = SiloSendPacket(
        packetType: PacketType.handshakeInit,
        packetId: 1,
        sourceDeviceId: sourceId,
        destinationDeviceId: destId,
        payload: samplePayload,
      );

      final bytes = packet.toBytes();
      bytes[0] = 0x00; // Corrupt magic

      expect(
        () => SiloSendPacket.fromBytes(bytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Invalid packet magic'),
          ),
        ),
      );
    });

    test('rejects packet with unsupported protocol version', () {
      final packet = SiloSendPacket(
        packetType: PacketType.handshakeInit,
        packetId: 1,
        sourceDeviceId: sourceId,
        destinationDeviceId: destId,
        payload: samplePayload,
      );

      final bytes = packet.toBytes();
      bytes[2] = 99; // Corrupt version

      expect(
        () => SiloSendPacket.fromBytes(bytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unsupported protocol version'),
          ),
        ),
      );
    });

    test('rejects packet with corrupted payload (CRC32 failure)', () {
      final packet = SiloSendPacket(
        packetType: PacketType.transferChunk,
        packetId: 50,
        sourceDeviceId: sourceId,
        destinationDeviceId: destId,
        payload: samplePayload,
      );

      final bytes = packet.toBytes();
      // Flip a bit in the payload area
      bytes[SiloSendPacket.headerSize] ^= 0xFF;

      expect(
        () => SiloSendPacket.fromBytes(bytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('CRC32 checksum mismatch'),
          ),
        ),
      );
    });

    test('rejects truncated byte streams', () {
      expect(
        () => SiloSendPacket.fromBytes(Uint8List(20)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Packet too short'),
          ),
        ),
      );
    });

    test('allows TTL modification via copyWith for relay forwarding', () {
      final original = SiloSendPacket(
        packetType: PacketType.chatMessage,
        packetId: 1,
        sourceDeviceId: sourceId,
        destinationDeviceId: destId,
        ttl: 3,
        payload: samplePayload,
      );

      final forwarded = original.copyWith(ttl: original.ttl - 1);
      expect(forwarded.ttl, equals(2));
      expect(forwarded.sourceDeviceId, equals(sourceId));
      expect(forwarded.destinationDeviceId, equals(destId));

      // Ensure newly encoded forwarded packet has valid CRC
      final decoded = SiloSendPacket.fromBytes(forwarded.toBytes());
      expect(decoded.ttl, equals(2));
    });

    test('validates 16-byte requirement for source and destination IDs', () {
      expect(
        () => SiloSendPacket(
          packetType: PacketType.ping,
          packetId: 1,
          sourceDeviceId: Uint8List(15), // invalid
          destinationDeviceId: destId,
          payload: Uint8List(0),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
