import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/security/crypto_service.dart';
import 'package:silosend_datasharing_app/domain/security/auth_exchange_payload.dart';

void main() {
  group('CryptoService Tests', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = CryptoService();
    });

    test(
      'Ed25519 keypair generation and signing verification for M_init & M_resp',
      () async {
        final keypairA = await cryptoService.generateIdentityKeypair();
        expect(keypairA.publicKey.length, 32);
        expect(keypairA.privateKeySeed!.length, 32);
        expect(keypairA.fingerprint.length, 32);
        expect(keypairA.fingerprintHex.length, 64);

        final keypairB = await cryptoService.generateIdentityKeypair();

        final sessionId = Uint8List.fromList(List.generate(16, (i) => i + 1));
        final devIdA = Uint8List.fromList(List.generate(16, (i) => i + 10));
        final devIdB = Uint8List.fromList(List.generate(16, (i) => i + 20));
        final ephPubA = Uint8List.fromList(List.generate(32, (i) => i + 30));
        final nonceA = Uint8List.fromList(List.generate(32, (i) => i + 40));

        // 1. M_init (exact 168 bytes)
        final mInit = AuthInitPayload.constructSigningMessage(
          sessionId: sessionId,
          initiatorDeviceId: devIdA,
          responderDeviceId: devIdB,
          initiatorEphemeralPubKey: ephPubA,
          initiatorNonce: nonceA,
          initiatorIdentityPubKey: keypairA.publicKey,
        );
        expect(mInit.length, 168);

        final sigA = await cryptoService.signEd25519(
          message: mInit,
          privateKeySeed: keypairA.privateKeySeed!,
        );
        expect(sigA.length, 64);

        final validSigA = await cryptoService.verifyEd25519(
          message: mInit,
          signature: sigA,
          publicKey: keypairA.publicKey,
        );
        expect(validSigA, isTrue);

        // Tampered message rejection
        final tamperedMInit = Uint8List.fromList(mInit);
        tamperedMInit[50] ^= 0xFF;
        final invalidSigA1 = await cryptoService.verifyEd25519(
          message: tamperedMInit,
          signature: sigA,
          publicKey: keypairA.publicKey,
        );
        expect(invalidSigA1, isFalse);

        // Tampered signature rejection
        final tamperedSigA = Uint8List.fromList(sigA);
        tamperedSigA[10] ^= 0x01;
        final invalidSigA2 = await cryptoService.verifyEd25519(
          message: mInit,
          signature: tamperedSigA,
          publicKey: keypairA.publicKey,
        );
        expect(invalidSigA2, isFalse);

        // Wrong public key rejection
        final invalidSigA3 = await cryptoService.verifyEd25519(
          message: mInit,
          signature: sigA,
          publicKey: keypairB.publicKey,
        );
        expect(invalidSigA3, isFalse);

        // 2. M_resp (exact 204 bytes)
        final initChallengeHash =
            HandshakeTranscriptHelper.computeInitiatorChallengeHash(
              mInit: mInit,
              sigA: sigA,
            );
        expect(initChallengeHash.length, 32);

        final ephPubB = Uint8List.fromList(List.generate(32, (i) => i + 50));
        final nonceB = Uint8List.fromList(List.generate(32, (i) => i + 60));

        final mResp = AuthResponsePayload.constructSigningMessage(
          sessionId: sessionId,
          responderDeviceId: devIdB,
          initiatorDeviceId: devIdA,
          responderEphemeralPubKey: ephPubB,
          responderNonce: nonceB,
          responderIdentityPubKey: keypairB.publicKey,
          initiatorChallengeHash: initChallengeHash,
        );
        expect(mResp.length, 204);

        final sigB = await cryptoService.signEd25519(
          message: mResp,
          privateKeySeed: keypairB.privateKeySeed!,
        );
        expect(sigB.length, 64);

        final validSigB = await cryptoService.verifyEd25519(
          message: mResp,
          signature: sigB,
          publicKey: keypairB.publicKey,
        );
        expect(validSigB, isTrue);
      },
    );

    test('X25519 ECDH shared secret derivation agreement (A_priv * B_pub == B_priv * A_pub)', () async {
      final ephPairA = await cryptoService.generateEphemeralX25519Keypair();
      final ephPairB = await cryptoService.generateEphemeralX25519Keypair();

      final ephPubA = await cryptoService.extractX25519PublicKey(ephPairA);
      final ephPubB = await cryptoService.extractX25519PublicKey(ephPairB);

      expect(ephPubA.length, 32);
      expect(ephPubB.length, 32);

      final sharedSecretA = await cryptoService.computeSharedSecret(
        localKeyPair: ephPairA,
        remotePublicKeyBytes: ephPubB,
      );

      final sharedSecretB = await cryptoService.computeSharedSecret(
        localKeyPair: ephPairB,
        remotePublicKeyBytes: ephPubA,
      );

      expect(sharedSecretA.length, 32);
      expect(sharedSecretB.length, 32);
      expect(sharedSecretA, equals(sharedSecretB));
    });

    test('HKDF-SHA256 derivation outputs distinct directional keys and exact lengths', () async {
      final sharedSecret = Uint8List(32)..fillRange(0, 32, 0x42);
      final nonceA = Uint8List(32)..fillRange(0, 32, 0x11);
      final nonceB = Uint8List(32)..fillRange(0, 32, 0x22);
      final sessionId = Uint8List(16)..fillRange(0, 16, 0x99);
      final transcriptHash = Uint8List(32)..fillRange(0, 32, 0xAA);

      final keys = await cryptoService.deriveSessionKeys(
        sharedSecret: sharedSecret,
        initiatorNonce: nonceA,
        responderNonce: nonceB,
        sessionId: sessionId,
        transcriptHash: transcriptHash,
      );

      expect(keys.keyInitToResp.length, 32);
      expect(keys.keyRespToInit.length, 32);
      expect(keys.saltInitNonce.length, 4);
      expect(keys.saltRespNonce.length, 4);
      expect(keys.confirmKey.length, 32);
      expect(keys.sasKey.length, 16);

      // Ensure distinctness
      expect(keys.keyInitToResp, isNot(equals(keys.keyRespToInit)));
      expect(keys.keyInitToResp, isNot(equals(keys.confirmKey)));
      expect(keys.saltInitNonce, isNot(equals(keys.saltRespNonce)));

      // Confirm MAC computation
      final macInit = await cryptoService.computeConfirmMac(
        confirmKey: keys.confirmKey,
        label: 'init-confirm:',
        transcriptHash: transcriptHash,
      );
      expect(macInit.length, 32);

      final macResp = await cryptoService.computeConfirmMac(
        confirmKey: keys.confirmKey,
        label: 'resp-confirm:',
        transcriptHash: transcriptHash,
      );
      expect(macResp.length, 32);
      expect(macInit, isNot(equals(macResp)));
    });

    test(
      'AES-256-GCM AEAD encryption and decryption with exact 76-byte AAD',
      () async {
        final key = Uint8List.fromList(List.generate(32, (i) => (i * 7) % 256));
        final nonce = Uint8List.fromList(List.generate(12, (i) => i));
        final plaintext = Uint8List.fromList(
          'Hello SiloSend Confidential Wire!'.codeUnits,
        );

        final aad = CryptoService.constructAad(
          magic1: 0x53,
          magic2: 0x53,
          protocolVersion: 1,
          packetTypeCode: 0x11, // transferChunk
          packetId: 123456789,
          sourceDeviceId: Uint8List(16)..fillRange(0, 16, 1),
          destinationDeviceId: Uint8List(16)..fillRange(0, 16, 2),
          payloadLength: plaintext.length + 25, // Envelope overhead
          sessionId: Uint8List(16)..fillRange(0, 16, 3),
          aeadNonce: nonce,
        );

        expect(aad.length, 76);

        // Encrypt
        final encrypted = await cryptoService.encryptAead(
          plaintext: plaintext,
          secretKeyBytes: key,
          nonce: nonce,
          aad: aad,
        );

        expect(encrypted.ciphertext.length, plaintext.length);
        expect(encrypted.authTag.length, 16);

        // Decrypt
        final decrypted = await cryptoService.decryptAead(
          ciphertext: encrypted.ciphertext,
          authTag: encrypted.authTag,
          secretKeyBytes: key,
          nonce: nonce,
          aad: aad,
        );

        expect(decrypted, equals(plaintext));

        // 1. Alter ciphertext -> Tag verification failure
        final tamperedCiphertext = Uint8List.fromList(encrypted.ciphertext);
        tamperedCiphertext[0] ^= 0x01;
        expect(
          () async => await cryptoService.decryptAead(
            ciphertext: tamperedCiphertext,
            authTag: encrypted.authTag,
            secretKeyBytes: key,
            nonce: nonce,
            aad: aad,
          ),
          throwsA(anything),
        );

        // 2. Alter AAD -> Tag verification failure
        final tamperedAad = Uint8List.fromList(aad);
        tamperedAad[15] ^= 0xFF; // Flip byte in source device ID
        expect(
          () async => await cryptoService.decryptAead(
            ciphertext: encrypted.ciphertext,
            authTag: encrypted.authTag,
            secretKeyBytes: key,
            nonce: nonce,
            aad: tamperedAad,
          ),
          throwsA(anything),
        );

        // 3. Alter Tag -> Failure
        final tamperedTag = Uint8List.fromList(encrypted.authTag);
        tamperedTag[15] ^= 0xFF;
        expect(
          () async => await cryptoService.decryptAead(
            ciphertext: encrypted.ciphertext,
            authTag: tamperedTag,
            secretKeyBytes: key,
            nonce: nonce,
            aad: aad,
          ),
          throwsA(anything),
        );
      },
    );

    test('secureWipe overwrites buffer in place', () {
      final buffer = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      CryptoService.secureWipe(buffer);
      for (final byte in buffer) {
        expect(byte, equals(0));
      }
    });
  });
}
