import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/security/trust_record_storage.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/security/trust_level.dart';

void main() {
  group('Identity key persistence', () {
    test(
      'a reloaded seed yields the same public key and valid signatures',
      () async {
        final crypto = CryptoService();
        final store = InMemorySecureKeyStore();
        final identity = LocalDeviceIdentity.generate(
          displayName: 'A',
          platform: 'android',
        );

        final firstRun = SecureSessionManager(
          cryptoService: crypto,
          trustStore: PeerTrustStore(),
          secureKeyStore: store,
          localIdentity: identity,
        );
        final minted = await firstRun.getOrInitializeLocalKeypair();

        // Simulated app restart: a new manager reads the same stored seed.
        final secondRun = SecureSessionManager(
          cryptoService: crypto,
          trustStore: PeerTrustStore(),
          secureKeyStore: store,
          localIdentity: identity,
        );
        final reloaded = await secondRun.getOrInitializeLocalKeypair();

        expect(reloaded.publicKey, minted.publicKey);
        expect(reloaded.fingerprintHex, minted.fingerprintHex);

        final message = Uint8List.fromList('handshake transcript'.codeUnits);
        final signature = await crypto.signEd25519(
          message: message,
          privateKeySeed: reloaded.privateKeySeed!,
        );
        expect(
          await crypto.verifyEd25519(
            message: message,
            signature: signature,
            publicKey: minted.publicKey,
          ),
          isTrue,
        );
      },
    );
  });

  group('Peer trust persistence', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('vayu_trust_');
      file = File('${dir.path}/peer_trust.json');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Uint8List key(int seed) =>
        Uint8List.fromList(List.generate(32, (i) => (i + seed) & 0xff));

    test(
      'trusted peers survive a restart and are promoted on return',
      () async {
        final first = PeerTrustStore(storage: FileTrustRecordStorage(file));
        expect(
          await first.evaluatePeer(
            deviceIdHex: 'AB01',
            presentedIdentityPubKey: key(1),
          ),
          TrustLevel.unverifiedTOFU,
        );

        final restarted = PeerTrustStore(storage: FileTrustRecordStorage(file));
        await restarted.load();
        expect(restarted.getTrustLevel('ab01'), TrustLevel.unverifiedTOFU);
        expect(
          await restarted.evaluatePeer(
            deviceIdHex: 'ab01',
            presentedIdentityPubKey: key(1),
          ),
          TrustLevel.trustedTOFU,
        );
      },
    );

    test(
      'a changed key is still flagged as a conflict after restart',
      () async {
        final first = PeerTrustStore(storage: FileTrustRecordStorage(file));
        await first.evaluatePeer(
          deviceIdHex: 'cd02',
          presentedIdentityPubKey: key(2),
        );

        final restarted = PeerTrustStore(storage: FileTrustRecordStorage(file));
        await restarted.load();
        await expectLater(
          restarted.evaluatePeer(
            deviceIdHex: 'cd02',
            presentedIdentityPubKey: key(9),
          ),
          throwsA(isA<IdentityKeyConflictException>()),
        );

        final afterConflict = PeerTrustStore(
          storage: FileTrustRecordStorage(file),
        );
        await afterConflict.load();
        expect(afterConflict.getTrustLevel('cd02'), TrustLevel.keyConflict);
      },
    );

    test('SAS verification is remembered', () async {
      final first = PeerTrustStore(storage: FileTrustRecordStorage(file));
      await first.promoteToSasVerified('ef03', key(3));

      final restarted = PeerTrustStore(storage: FileTrustRecordStorage(file));
      await restarted.load();
      expect(restarted.getTrustLevel('ef03'), TrustLevel.sasVerified);
    });

    test('a corrupt file starts empty instead of crashing', () async {
      file.writeAsStringSync('{not json');
      final store = PeerTrustStore(storage: FileTrustRecordStorage(file));
      await store.load();
      expect(store.records, isEmpty);
    });
  });
}
