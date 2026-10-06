import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/domain/connection/handshake_payload.dart';

void main() {
  group('HandshakePayload', () {
    const validHexId = '0123456789abcdef0123456789abcdef';
    const validSessionId = 'sess-1234567890abcdef12345678';

    test('serializes to and from JSON correctly', () {
      final payload = HandshakePayload(
        protocolVersion: 1,
        sessionId: validSessionId,
        deviceIdHex: validHexId,
        displayName: 'Pixel 8 Pro',
        platform: 'android',
        supportedTransports: {TransportType.lan, TransportType.ble},
        accepted: true,
        timestamp: 1700000000000,
      );

      final json = payload.toJson();
      final restored = HandshakePayload.fromJson(json);

      expect(restored.protocolVersion, 1);
      expect(restored.sessionId, validSessionId);
      expect(restored.deviceIdHex, validHexId);
      expect(restored.displayName, 'Pixel 8 Pro');
      expect(restored.platform, 'android');
      expect(
        restored.supportedTransports,
        containsAll([TransportType.lan, TransportType.ble]),
      );
      expect(restored.accepted, isTrue);
      expect(restored.rejectionReason, isNull);
      expect(restored.timestamp, 1700000000000);
    });

    test('serializes to and from bytes correctly', () {
      final payload = HandshakePayload(
        sessionId: validSessionId,
        deviceIdHex: validHexId,
        displayName: 'Laptop-Windows',
        platform: 'windows',
        accepted: false,
        rejectionReason: 'protocol_version_mismatch',
      );

      final bytes = payload.toBytes();
      expect(bytes, isA<Uint8List>());
      expect(bytes.isNotEmpty, isTrue);

      final restored = HandshakePayload.fromBytes(bytes);
      expect(restored.sessionId, validSessionId);
      expect(restored.deviceIdHex, validHexId);
      expect(restored.displayName, 'Laptop-Windows');
      expect(restored.accepted, isFalse);
      expect(restored.rejectionReason, 'protocol_version_mismatch');
    });

    test('converts deviceIdHex to 16-byte Uint8List', () {
      final payload = HandshakePayload(
        sessionId: validSessionId,
        deviceIdHex: '000102030405060708090a0b0c0d0e0f',
        displayName: 'TestDevice',
        platform: 'linux',
      );

      final bytes = payload.deviceIdBytes;
      expect(bytes.length, 16);
      expect(bytes[0], 0x00);
      expect(bytes[1], 0x01);
      expect(bytes[15], 0x0f);
    });

    test('clamps long display names to max 32 UTF-8 bytes', () {
      const veryLongName =
          'ThisIsAVeryLongDeviceDisplayNameThatExceedsThe32ByteLimitEasily';
      final payload = HandshakePayload(
        sessionId: validSessionId,
        deviceIdHex: validHexId,
        displayName: veryLongName,
        platform: 'android',
      );

      final encoded = utf8.encode(payload.displayName);
      expect(encoded.length, lessThanOrEqualTo(32));
    });

    test('strips control characters and falls back when empty', () {
      final payload = HandshakePayload(
        sessionId: validSessionId,
        deviceIdHex: validHexId,
        displayName: '\x00\x01\x1f\n\r',
        platform: 'android',
      );

      expect(payload.displayName, 'Vayu-Device');
    });

    test('validates device ID hex format and length', () {
      expect(
        () => HandshakePayload(
          sessionId: validSessionId,
          deviceIdHex: 'short_id',
          displayName: 'Test',
          platform: 'android',
        ),
        throwsArgumentError,
      );

      expect(
        () => HandshakePayload(
          sessionId: validSessionId,
          deviceIdHex: 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
          displayName: 'Test',
          platform: 'android',
        ),
        throwsArgumentError,
      );
    });

    test('validates non-empty sessionId', () {
      expect(
        () => HandshakePayload(
          sessionId: '   ',
          deviceIdHex: validHexId,
          displayName: 'Test',
          platform: 'android',
        ),
        throwsArgumentError,
      );
    });

    test('throws FormatException on malformed payload bytes', () {
      final invalidBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(
        () => HandshakePayload.fromBytes(invalidBytes),
        throwsFormatException,
      );
    });
  });
}
