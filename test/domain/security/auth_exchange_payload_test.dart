import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/domain/security/auth_exchange_payload.dart';
import 'package:vayu/domain/security/encrypted_envelope.dart';

void main() {
  group('AuthExchangePayload and Wire Framing Audit Tests', () {
    test(
      'AuthInitPayload serializes and deserializes exact 180-byte wire frame',
      () {
        final payload = AuthInitPayload(
          sessionId: Uint8List(16)..fillRange(0, 16, 0x10),
          ephemeralPubKey: Uint8List(32)..fillRange(0, 32, 0x20),
          nonce: Uint8List(32)..fillRange(0, 32, 0x30),
          identityPubKey: Uint8List(32)..fillRange(0, 32, 0x40),
          signature: Uint8List(64)..fillRange(0, 64, 0x50),
        );

        final bytes = payload.toBytes();
        expect(bytes.length, 180);

        final decoded = AuthInitPayload.fromBytes(bytes);
        expect(decoded.protocolVersion, 1);
        expect(decoded.cipherSuite, 0x0001);
        expect(decoded.sessionId, equals(payload.sessionId));
        expect(decoded.ephemeralPubKey, equals(payload.ephemeralPubKey));
        expect(decoded.nonce, equals(payload.nonce));
        expect(decoded.identityPubKey, equals(payload.identityPubKey));
        expect(decoded.signature, equals(payload.signature));
      },
    );

    test('AuthResponsePayload serializes and deserializes exact 212-byte wire frame', () {
      final payload = AuthResponsePayload(
        sessionId: Uint8List(16)..fillRange(0, 16, 0x10),
        ephemeralPubKey: Uint8List(32)..fillRange(0, 32, 0x20),
        nonce: Uint8List(32)..fillRange(0, 32, 0x30),
        identityPubKey: Uint8List(32)..fillRange(0, 32, 0x40),
        signature: Uint8List(64)..fillRange(0, 64, 0x50),
        confirmMac: Uint8List(32)..fillRange(0, 32, 0x60),
      );

      final bytes = payload.toBytes();
      expect(bytes.length, 212);

      final decoded = AuthResponsePayload.fromBytes(bytes);
      expect(decoded.protocolVersion, 1);
      expect(decoded.cipherSuite, 0x0001);
      expect(decoded.sessionId, equals(payload.sessionId));
      expect(decoded.ephemeralPubKey, equals(payload.ephemeralPubKey));
      expect(decoded.nonce, equals(payload.nonce));
      expect(decoded.identityPubKey, equals(payload.identityPubKey));
      expect(decoded.signature, equals(payload.signature));
      expect(decoded.confirmMac, equals(payload.confirmMac));
    });

    test(
      'AuthConfirmPayload serializes and deserializes exact 49-byte wire frame',
      () {
        final payload = AuthConfirmPayload(
          sessionId: Uint8List(16)..fillRange(0, 16, 0x10),
          confirmMac: Uint8List(32)..fillRange(0, 32, 0x60),
        );

        final bytes = payload.toBytes();
        expect(bytes.length, 49);

        final decoded = AuthConfirmPayload.fromBytes(bytes);
        expect(decoded.sessionId, equals(payload.sessionId));
        expect(decoded.confirmMac, equals(payload.confirmMac));
      },
    );

    test('EncryptedEnvelope serializes and deserializes with exact 25-byte overhead', () {
      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final envelope = EncryptedEnvelope(
        epoch: 2,
        sequenceNumber: 1045,
        ciphertext: plaintext,
        authTag: Uint8List(16)..fillRange(0, 16, 0xAA),
      );

      final bytes = envelope.toBytes();
      expect(bytes.length, 25 + plaintext.length);

      final decoded = EncryptedEnvelope.fromBytes(bytes);
      expect(decoded.epoch, 2);
      expect(decoded.sequenceNumber, 1045);
      expect(decoded.ciphertext, equals(plaintext));
      expect(decoded.authTag, equals(envelope.authTag));
    });

    test('M_init, M_resp, and Transcript byte-level size audit', () {
      final mInit = AuthInitPayload.constructSigningMessage(
        sessionId: Uint8List(16),
        initiatorDeviceId: Uint8List(16),
        responderDeviceId: Uint8List(16),
        initiatorEphemeralPubKey: Uint8List(32),
        initiatorNonce: Uint8List(32),
        initiatorIdentityPubKey: Uint8List(32),
      );
      expect(mInit.length, 168);

      final mResp = AuthResponsePayload.constructSigningMessage(
        sessionId: Uint8List(16),
        responderDeviceId: Uint8List(16),
        initiatorDeviceId: Uint8List(16),
        responderEphemeralPubKey: Uint8List(32),
        responderNonce: Uint8List(32),
        responderIdentityPubKey: Uint8List(32),
        initiatorChallengeHash: Uint8List(32),
      );
      expect(mResp.length, 204);

      final sigA = Uint8List(64);
      final sigB = Uint8List(64);

      final transcriptHash = HandshakeTranscriptHelper.computeTranscriptHash(
        mInit: mInit,
        sigA: sigA,
        mResp: mResp,
        sigB: sigB,
      );
      expect(transcriptHash.length, 32);

      // Audit exact 76-byte AAD
      final aad = CryptoService.constructAad(
        magic1: 0x53,
        magic2: 0x53,
        protocolVersion: 1,
        packetTypeCode: 0x11,
        packetId: 1,
        sourceDeviceId: Uint8List(16),
        destinationDeviceId: Uint8List(16),
        payloadLength: 100,
        sessionId: Uint8List(16),
        aeadNonce: Uint8List(12),
      );
      expect(aad.length, 76);
    });

    test('throws FormatException on malformed payload lengths', () {
      expect(
        () => AuthInitPayload.fromBytes(Uint8List(179)),
        throwsFormatException,
      );
      expect(
        () => AuthResponsePayload.fromBytes(Uint8List(211)),
        throwsFormatException,
      );
      expect(
        () => AuthConfirmPayload.fromBytes(Uint8List(48)),
        throwsFormatException,
      );
      expect(
        () => EncryptedEnvelope.fromBytes(Uint8List(24)),
        throwsFormatException,
      );
      expect(
        () => RekeyInitPayload.fromBytes(Uint8List(179)),
        throwsFormatException,
      );
      expect(
        () => RekeyResponsePayload.fromBytes(Uint8List(211)),
        throwsFormatException,
      );
      expect(
        () => RekeyConfirmPayload.fromBytes(Uint8List(50)),
        throwsFormatException,
      );
    });

    test(
      'RekeyInitPayload serializes and deserializes exact 180-byte wire frame',
      () {
        final payload = RekeyInitPayload(
          targetEpoch: 2,
          sessionId: Uint8List(16)..fillRange(0, 16, 0x11),
          ephemeralPubKey: Uint8List(32)..fillRange(0, 32, 0x22),
          nonce: Uint8List(32)..fillRange(0, 32, 0x33),
          prevEpochMac: Uint8List(32)..fillRange(0, 32, 0x44),
          signature: Uint8List(64)..fillRange(0, 64, 0x55),
        );

        final bytes = payload.toBytes();
        expect(bytes.length, 180);

        final decoded = RekeyInitPayload.fromBytes(bytes);
        expect(decoded.protocolVersion, 1);
        expect(decoded.targetEpoch, 2);
        expect(decoded.sessionId, equals(payload.sessionId));
        expect(decoded.ephemeralPubKey, equals(payload.ephemeralPubKey));
        expect(decoded.nonce, equals(payload.nonce));
        expect(decoded.prevEpochMac, equals(payload.prevEpochMac));
        expect(decoded.signature, equals(payload.signature));
      },
    );

    test('RekeyResponsePayload serializes and deserializes exact 212-byte wire frame', () {
      final payload = RekeyResponsePayload(
        targetEpoch: 2,
        sessionId: Uint8List(16)..fillRange(0, 16, 0x11),
        ephemeralPubKey: Uint8List(32)..fillRange(0, 32, 0x22),
        nonce: Uint8List(32)..fillRange(0, 32, 0x33),
        initChallengeHash: Uint8List(32)..fillRange(0, 32, 0x44),
        signature: Uint8List(64)..fillRange(0, 64, 0x55),
        confirmMac: Uint8List(32)..fillRange(0, 32, 0x66),
      );

      final bytes = payload.toBytes();
      expect(bytes.length, 212);

      final decoded = RekeyResponsePayload.fromBytes(bytes);
      expect(decoded.protocolVersion, 1);
      expect(decoded.targetEpoch, 2);
      expect(decoded.sessionId, equals(payload.sessionId));
      expect(decoded.ephemeralPubKey, equals(payload.ephemeralPubKey));
      expect(decoded.nonce, equals(payload.nonce));
      expect(decoded.initChallengeHash, equals(payload.initChallengeHash));
      expect(decoded.signature, equals(payload.signature));
      expect(decoded.confirmMac, equals(payload.confirmMac));
    });

    test('RekeyConfirmPayload serializes and deserializes exact 51-byte wire frame', () {
      final payload = RekeyConfirmPayload(
        targetEpoch: 2,
        sessionId: Uint8List(16)..fillRange(0, 16, 0x11),
        confirmMac: Uint8List(32)..fillRange(0, 32, 0x44),
      );

      final bytes = payload.toBytes();
      expect(bytes.length, 51);

      final decoded = RekeyConfirmPayload.fromBytes(bytes);
      expect(decoded.targetEpoch, 2);
      expect(decoded.sessionId, equals(payload.sessionId));
      expect(decoded.confirmMac, equals(payload.confirmMac));
    });

    test(
      'M_rekey_init, M_rekey_resp, and Rekey Transcript byte-level size audit',
      () {
        final mRekeyInit = RekeyInitPayload.constructSigningMessage(
          targetEpoch: 1,
          sessionId: Uint8List(16),
          initiatorDeviceId: Uint8List(16),
          responderDeviceId: Uint8List(16),
          initiatorEphemeralPubKey: Uint8List(32),
          initiatorNonce: Uint8List(32),
          initiatorIdentityPubKey: Uint8List(32),
        );
        expect(mRekeyInit.length, 169);

        final sigInit = Uint8List(64);
        final challengeHash =
            RekeyTranscriptHelper.computeInitiatorChallengeHash(
              mRekeyInit: mRekeyInit,
              sigInit: sigInit,
            );
        expect(challengeHash.length, 32);

        final mRekeyResp = RekeyResponsePayload.constructSigningMessage(
          targetEpoch: 1,
          sessionId: Uint8List(16),
          responderDeviceId: Uint8List(16),
          initiatorDeviceId: Uint8List(16),
          responderEphemeralPubKey: Uint8List(32),
          responderNonce: Uint8List(32),
          responderIdentityPubKey: Uint8List(32),
          initiatorChallengeHash: challengeHash,
        );
        expect(mRekeyResp.length, 205);

        final sigResp = Uint8List(64);

        // Total transcript: 169 + 64 + 205 + 64 = 502 bytes
        final transcriptHash = RekeyTranscriptHelper.computeTranscriptHash(
          mRekeyInit: mRekeyInit,
          sigInit: sigInit,
          mRekeyResp: mRekeyResp,
          sigResp: sigResp,
        );
        expect(transcriptHash.length, 32);
      },
    );
  });
}
