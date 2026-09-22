import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/domain/pairing/pairing_payload.dart';

void main() {
  group('PairingPayload', () {
    const validHexId = '0123456789abcdef0123456789abcdef';
    const validToken = 'tok-abcdef1234567890abcdef123456';

    test('serializes to and from JSON correctly', () {
      final payload = PairingPayload(
        protocolVersion: 1,
        deviceIdHex: validHexId,
        displayName: 'Pixel 8',
        supportedTransports: {TransportType.lan, TransportType.ble},
        lanAddress: '192.168.1.100',
        lanPort: 53531,
        bleServiceUuid: '00005353-0000-1000-8000-00805f9b34fb',
        bleDeviceAddress: 'AA:BB:CC:DD:EE:FF',
        pairingToken: validToken,
        timestamp: 1700000000000,
      );

      final json = payload.toJson();
      final restored = PairingPayload.fromJson(json);

      expect(restored.protocolVersion, 1);
      expect(restored.deviceIdHex, validHexId);
      expect(restored.displayName, 'Pixel 8');
      expect(
        restored.supportedTransports,
        containsAll([TransportType.lan, TransportType.ble]),
      );
      expect(restored.lanAddress, '192.168.1.100');
      expect(restored.lanPort, 53531);
      expect(restored.bleServiceUuid, '00005353-0000-1000-8000-00805f9b34fb');
      expect(restored.bleDeviceAddress, 'AA:BB:CC:DD:EE:FF');
      expect(restored.pairingToken, validToken);
      expect(restored.timestamp, 1700000000000);
    });

    test('serializes to and from standard silosend://pair URI', () {
      final payload = PairingPayload(
        protocolVersion: 1,
        deviceIdHex: validHexId,
        displayName: 'Galaxy S23',
        supportedTransports: {TransportType.lan},
        lanAddress: '192.168.0.50',
        lanPort: 53531,
        pairingToken: validToken,
        timestamp: 1710000000000,
      );

      final uri = payload.toUri();
      expect(uri.scheme, 'silosend');
      expect(uri.host, 'pair');

      final restored = PairingPayload.fromUri(uri);
      expect(restored.deviceIdHex, validHexId);
      expect(restored.displayName, 'Galaxy S23');
      expect(restored.supportedTransports, contains(TransportType.lan));
      expect(restored.lanAddress, '192.168.0.50');
      expect(restored.lanPort, 53531);
      expect(restored.pairingToken, validToken);
    });

    test(
      'serializes to and from standard NDEF MIME record bytes (short record)',
      () {
        final payload = PairingPayload(
          deviceIdHex: validHexId,
          displayName: 'Desktop-Workstation',
          supportedTransports: {TransportType.lan},
          lanAddress: '10.0.0.5',
          lanPort: 53531,
          pairingToken: validToken,
        );

        final ndefBytes = payload.toNdefBytes();
        expect(ndefBytes, isA<Uint8List>());
        expect(ndefBytes.isNotEmpty, isTrue);

        // Verify NDEF header flags (MB=1, ME=1, SR=1, TNF=0x02) -> 0xD2
        expect(ndefBytes[0], 0xD2);

        final restored = PairingPayload.fromNdefBytes(ndefBytes);
        expect(restored.deviceIdHex, validHexId);
        expect(restored.displayName, 'Desktop-Workstation');
        expect(restored.pairingToken, validToken);
        expect(restored.lanAddress, '10.0.0.5');
        expect(restored.lanPort, 53531);
      },
    );

    test('serializes to and from standard NDEF MIME record bytes (normal record > 255 bytes)', () {
      final payload = PairingPayload(
        deviceIdHex: validHexId,
        displayName: 'A-Very-Long-Device-Name-32Bytes',
        supportedTransports: {
          TransportType.lan,
          TransportType.ble,
          TransportType.wifiDirect,
        },
        lanAddress: '192.168.123.234',
        lanPort: 53531,
        bleServiceUuid: '00005353-0000-1000-8000-00805f9b34fb',
        bleDeviceAddress: '11:22:33:44:55:66',
        pairingToken: 'tok-very-long-custom-pairing-token-that-stretches-the-payload-size-a-lot-1234567890',
      );

      final ndefBytes = payload.toNdefBytes();
      final restored = PairingPayload.fromNdefBytes(ndefBytes);

      expect(restored.deviceIdHex, validHexId);
      expect(restored.displayName, 'A-Very-Long-Device-Name-32Bytes');
      expect(restored.bleDeviceAddress, '11:22:33:44:55:66');
    });

    test('falls back to raw JSON byte decoding', () {
      final payload = PairingPayload(
        deviceIdHex: validHexId,
        displayName: 'RawJsonDevice',
        pairingToken: validToken,
      );

      final jsonBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(payload.toJson())),
      );
      final restored = PairingPayload.fromNdefBytes(jsonBytes);

      expect(restored.deviceIdHex, validHexId);
      expect(restored.displayName, 'RawJsonDevice');
      expect(restored.pairingToken, validToken);
    });

    test('clamps long display names to max 32 UTF-8 bytes', () {
      const longName =
          'ThisDeviceNameIsExceedinglyLongAndDefinitelyExceedsThe32ByteLimit';
      final payload = PairingPayload(
        deviceIdHex: validHexId,
        displayName: longName,
        pairingToken: validToken,
      );

      final bytes = utf8.encode(payload.displayName);
      expect(bytes.length, lessThanOrEqualTo(32));
    });

    test('sanitizes control characters and defaults empty name', () {
      final payload = PairingPayload(
        deviceIdHex: validHexId,
        displayName: '\x00\x01\x1f\n',
        pairingToken: validToken,
      );

      expect(payload.displayName, 'SiloSend-Device');
    });

    test('validates device ID hex format', () {
      expect(
        () => PairingPayload(
          deviceIdHex: 'not_32_chars',
          displayName: 'Test',
          pairingToken: validToken,
        ),
        throwsArgumentError,
      );

      expect(
        () => PairingPayload(
          deviceIdHex: 'gggggggggggggggggggggggggggggggg', // invalid hex
          displayName: 'Test',
          pairingToken: validToken,
        ),
        throwsArgumentError,
      );
    });

    test('validates non-empty pairing token', () {
      expect(
        () => PairingPayload(
          deviceIdHex: validHexId,
          displayName: 'Test',
          pairingToken: '   ',
        ),
        throwsArgumentError,
      );
    });

    test('validates port range when provided', () {
      expect(
        () => PairingPayload(
          deviceIdHex: validHexId,
          displayName: 'Test',
          pairingToken: validToken,
          lanPort: 70000,
        ),
        throwsArgumentError,
      );

      expect(
        () => PairingPayload(
          deviceIdHex: validHexId,
          displayName: 'Test',
          pairingToken: validToken,
          lanPort: 0,
        ),
        throwsArgumentError,
      );
    });

    test(
      'throws FormatException on malformed URI scheme or missing parameters',
      () {
        final invalidScheme = Uri.parse(
          'http://pair?id=$validHexId&token=$validToken',
        );
        expect(
          () => PairingPayload.fromUri(invalidScheme),
          throwsFormatException,
        );

        final missingToken = Uri.parse('silosend://pair?id=$validHexId');
        expect(
          () => PairingPayload.fromUri(missingToken),
          throwsFormatException,
        );
      },
    );

    test(
      'createWithNfcCommitment computes commitment and populates hex fields',
      () {
        final pubKey = Uint8List(32)..fillRange(0, 32, 0xAA);
        final secret = Uint8List(16)..fillRange(0, 16, 0xBB);

        final payload = PairingPayload.createWithNfcCommitment(
          deviceIdHex: validHexId,
          displayName: 'NFC-Device',
          pairingToken: validToken,
          ed25519PubKey: pubKey,
          pairingSecret: secret,
        );

        expect(payload.ed25519PubKeyHex, isNotNull);
        expect(payload.nfcCommitmentHex, isNotNull);
        expect(payload.ed25519PubKeyHex!.length, 64);
        expect(payload.nfcCommitmentHex!.length, 64);
        expect(payload.ed25519PubKeyBytes, equals(pubKey));
        expect(payload.pairingSecretBytes, equals(secret));

        final expectedCommitment = PairingPayload.computeCommitmentHex(
          ed25519PubKey: pubKey,
          pairingSecret: secret,
        );
        expect(payload.nfcCommitmentHex, equals(expectedCommitment));
      },
    );

    test(
      'serializes and deserializes NFC commitment across JSON, URI, and NDEF',
      () {
        final pubKey = Uint8List(32)..fillRange(0, 32, 0x12);
        final secret = Uint8List(16)..fillRange(0, 16, 0x34);

        final payload = PairingPayload.createWithNfcCommitment(
          deviceIdHex: validHexId,
          displayName: 'NFC-Roundtrip',
          pairingToken: validToken,
          ed25519PubKey: pubKey,
          pairingSecret: secret,
        );

        // 1. JSON
        final json = payload.toJson();
        expect(json['pubKey'], payload.ed25519PubKeyHex);
        expect(json['nfcCommitment'], payload.nfcCommitmentHex);
        final fromJson = PairingPayload.fromJson(json);
        expect(fromJson.ed25519PubKeyHex, payload.ed25519PubKeyHex);
        expect(fromJson.nfcCommitmentHex, payload.nfcCommitmentHex);

        // 2. URI
        final uri = payload.toUri();
        expect(uri.queryParameters['pk'], payload.ed25519PubKeyHex);
        expect(uri.queryParameters['nfc'], payload.nfcCommitmentHex);
        final fromUri = PairingPayload.fromUri(uri);
        expect(fromUri.ed25519PubKeyHex, payload.ed25519PubKeyHex);
        expect(fromUri.nfcCommitmentHex, payload.nfcCommitmentHex);

        // 3. NDEF
        final ndefBytes = payload.toNdefBytes();
        final fromNdef = PairingPayload.fromNdefBytes(ndefBytes);
        expect(fromNdef.ed25519PubKeyHex, payload.ed25519PubKeyHex);
        expect(fromNdef.nfcCommitmentHex, payload.nfcCommitmentHex);
      },
    );

    test(
      'deserialization detects tampered commitment and throws FormatException',
      () {
        final pubKey = Uint8List(32)..fillRange(0, 32, 0x12);
        final secret = Uint8List(16)..fillRange(0, 16, 0x34);

        final payload = PairingPayload.createWithNfcCommitment(
          deviceIdHex: validHexId,
          displayName: 'Tampered-Device',
          pairingToken: validToken,
          ed25519PubKey: pubKey,
          pairingSecret: secret,
        );

        final tamperedJson = payload.toJson();
        // Alter commitment
        tamperedJson['nfcCommitment'] =
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
        expect(
          () => PairingPayload.fromJson(tamperedJson),
          throwsFormatException,
        );

        // Alter public key in URI
        final tamperedUri = Uri.parse(
          payload.toUri().toString().replaceAll(
            payload.ed25519PubKeyHex!,
            '0000000000000000000000000000000000000000000000000000000000000000',
          ),
        );
        expect(
          () => PairingPayload.fromUri(tamperedUri),
          throwsFormatException,
        );
      },
    );

    test('validates hex length for ed25519PubKeyHex and nfcCommitmentHex', () {
      expect(
        () => PairingPayload(
          deviceIdHex: validHexId,
          displayName: 'Test',
          pairingToken: validToken,
          ed25519PubKeyHex: 'short',
        ),
        throwsArgumentError,
      );

      expect(
        () => PairingPayload(
          deviceIdHex: validHexId,
          displayName: 'Test',
          pairingToken: validToken,
          nfcCommitmentHex: 'short',
        ),
        throwsArgumentError,
      );
    });
  });
}
