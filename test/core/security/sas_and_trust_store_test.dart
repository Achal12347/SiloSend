import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/security/peer_trust_store.dart';
import 'package:silosend_datasharing_app/core/security/secure_key_store.dart';
import 'package:silosend_datasharing_app/core/security/short_authentication_string.dart';
import 'package:silosend_datasharing_app/domain/security/trust_level.dart';

void main() {
  group('SAS and TrustStore Tests', () {
    test('ShortAuthenticationString derives 6-digit numeric and 4-word representations', () {
      final sasKey = Uint8List(16);
      sasKey[0] = 0x12;
      sasKey[1] = 0x34;
      sasKey[2] = 0x56;
      sasKey[3] = 0x78;
      // Indices for words
      sasKey[4] = 0; // 'acorn'
      sasKey[5] = 2; // 'amber'
      sasKey[6] = 21; // 'beacon'
      sasKey[7] = 255; // 'zinc'

      final sas = ShortAuthenticationString.fromKey(sasKey);

      // Verify numeric formatting
      expect(sas.numeric.length, 7); // 3 digits + space + 3 digits
      expect(sas.numeric.contains(' '), isTrue);

      // Verify words
      expect(sas.words, 'acorn amber beacon zinc');

      // Determinism
      final sas2 = ShortAuthenticationString.fromKey(sasKey);
      expect(sas2.numeric, equals(sas.numeric));
      expect(sas2.words, equals(sas.words));
    });

    test(
      'PeerTrustStore handles first-contact TOFU and repeated contact',
      () async {
        final store = PeerTrustStore();
        final deviceIdHex = '0123456789abcdef0123456789abcdef';
        final pubKeyA = Uint8List(32)..fillRange(0, 32, 0x01);

        // 1. First contact -> unverifiedTOFU
        final level1 = await store.evaluatePeer(
          deviceIdHex: deviceIdHex,
          presentedIdentityPubKey: pubKeyA,
        );
        expect(level1, equals(TrustLevel.unverifiedTOFU));

        final record1 = await store.getPeerTrust(deviceIdHex);
        expect(record1, isNotNull);
        expect(record1!.trustLevel, equals(TrustLevel.unverifiedTOFU));

        // 2. Repeated contact -> promoted to trustedTOFU
        final level2 = await store.evaluatePeer(
          deviceIdHex: deviceIdHex,
          presentedIdentityPubKey: pubKeyA,
        );
        expect(level2, equals(TrustLevel.trustedTOFU));

        // 3. User verifies SAS -> sasVerified
        await store.updateTrustLevel(deviceIdHex, TrustLevel.sasVerified);
        final record3 = await store.getPeerTrust(deviceIdHex);
        expect(record3!.trustLevel, equals(TrustLevel.sasVerified));

        // Subsequent contact retains sasVerified
        final level3 = await store.evaluatePeer(
          deviceIdHex: deviceIdHex,
          presentedIdentityPubKey: pubKeyA,
        );
        expect(level3, equals(TrustLevel.sasVerified));
      },
    );

    test('PeerTrustStore detects key conflict and throws IdentityKeyConflictException', () async {
      final store = PeerTrustStore();
      final deviceIdHex = '0123456789abcdef0123456789abcdef';
      final pubKeyA = Uint8List(32)..fillRange(0, 32, 0x01);
      final pubKeyB = Uint8List(32)..fillRange(0, 32, 0x02);

      await store.evaluatePeer(
        deviceIdHex: deviceIdHex,
        presentedIdentityPubKey: pubKeyA,
      );

      // Presenting a different public key for the same deviceId must throw
      expect(
        () async => await store.evaluatePeer(
          deviceIdHex: deviceIdHex,
          presentedIdentityPubKey: pubKeyB,
        ),
        throwsA(isA<IdentityKeyConflictException>()),
      );

      final record = await store.getPeerTrust(deviceIdHex);
      expect(record!.trustLevel, equals(TrustLevel.keyConflict));
    });

    test('PeerTrustStore verifies NFC cryptographic commitment', () async {
      final store = PeerTrustStore();
      final deviceIdHex = '0123456789abcdef0123456789abcdef';
      final pubKey = Uint8List(32)..fillRange(0, 32, 0x77);
      final pairingSecret = Uint8List(16)..fillRange(0, 16, 0x88);

      final commitment = PeerTrustStore.computeNfcCommitment(
        ed25519PubKey: pubKey,
        pairingSecret: pairingSecret,
      );
      expect(commitment.length, 32);

      // Evaluate with valid NFC commitment
      final level = await store.evaluatePeer(
        deviceIdHex: deviceIdHex,
        presentedIdentityPubKey: pubKey,
        nfcCommitment: commitment,
        pairingSecret: pairingSecret,
      );
      expect(level, equals(TrustLevel.nfcAuthenticated));
    });

    test('PeerTrustStore strictly throws NfcCommitmentMismatchException and NEVER falls back to TOFU on mismatch', () async {
      final store = PeerTrustStore();
      final deviceIdHex = '0123456789abcdef0123456789abcdef';
      final pubKey = Uint8List(32)..fillRange(0, 32, 0x77);
      final wrongPubKey = Uint8List(32)..fillRange(0, 32, 0x78);
      final pairingSecret = Uint8List(16)..fillRange(0, 16, 0x88);

      final commitment = PeerTrustStore.computeNfcCommitment(
        ed25519PubKey: pubKey,
        pairingSecret: pairingSecret,
      );

      // 1. Mismatched public key with genuine commitment
      expect(
        () => store.evaluatePeer(
          deviceIdHex: deviceIdHex,
          presentedIdentityPubKey: wrongPubKey,
          nfcCommitment: commitment,
          pairingSecret: pairingSecret,
        ),
        throwsA(isA<NfcCommitmentMismatchException>()),
      );

      // Ensure no TOFU record was quietly persisted
      final record1 = await store.getPeerTrust(deviceIdHex);
      expect(record1, isNull);

      // 2. Tampered commitment bytes
      final tamperedCommitment = Uint8List.fromList(commitment);
      tamperedCommitment[0] ^= 0xFF;
      expect(
        () => store.evaluatePeer(
          deviceIdHex: deviceIdHex,
          presentedIdentityPubKey: pubKey,
          nfcCommitment: tamperedCommitment,
          pairingSecret: pairingSecret,
        ),
        throwsA(isA<NfcCommitmentMismatchException>()),
      );
      expect(await store.getPeerTrust(deviceIdHex), isNull);

      // 3. Missing pairing secret when commitment is presented
      expect(
        () => store.evaluatePeer(
          deviceIdHex: deviceIdHex,
          presentedIdentityPubKey: pubKey,
          nfcCommitment: commitment,
          pairingSecret: null,
        ),
        throwsA(isA<NfcCommitmentMismatchException>()),
      );
      expect(await store.getPeerTrust(deviceIdHex), isNull);
    });

    test('InMemorySecureKeyStore roundtrip and wipe', () async {
      final keyStore = InMemorySecureKeyStore();
      expect(await keyStore.loadIdentitySeed(), isNull);

      final seed = Uint8List(32)..fillRange(0, 32, 0x99);
      await keyStore.saveIdentitySeed(seed);

      final loaded = await keyStore.loadIdentitySeed();
      expect(loaded, equals(seed));

      await keyStore.clearIdentitySeed();
      expect(await keyStore.loadIdentitySeed(), isNull);
    });
  });
}
