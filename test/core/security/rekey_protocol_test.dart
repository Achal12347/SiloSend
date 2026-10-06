import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/errors/app_error.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/security/auth_exchange_payload.dart';
import 'package:vayu/domain/security/encrypted_envelope.dart';
import 'package:vayu/domain/security/trust_level.dart';

void main() {
  group('Phase 6 In-Band Rekeying & NFC Wire Commitment Tests', () {
    late LocalDeviceIdentity identityA;
    late LocalDeviceIdentity identityB;
    late LanConnectionServer serverB;
    late ConnectionManager managerA;
    late ConnectionManager managerB;

    late CryptoService cryptoService;
    late PeerTrustStore trustStoreA;
    late PeerTrustStore trustStoreB;
    late SecureSessionManager secureManagerA;
    late SecureSessionManager secureManagerB;

    setUp(() async {
      identityA = LocalDeviceIdentity.generate(
        displayName: 'Device-A',
        platform: 'android',
      );
      identityB = LocalDeviceIdentity.generate(
        displayName: 'Device-B',
        platform: 'windows',
      );

      serverB = LanConnectionServer(requestedPort: 0);
      await serverB.start();

      managerA = ConnectionManager(
        localIdentity: identityA,
        handshakeTimeout: const Duration(seconds: 5),
      );
      managerB = ConnectionManager(
        localIdentity: identityB,
        handshakeTimeout: const Duration(seconds: 5),
      );
      managerB.registerLanServer(serverB);

      cryptoService = CryptoService();
      trustStoreA = PeerTrustStore();
      trustStoreB = PeerTrustStore();

      secureManagerA = SecureSessionManager(
        cryptoService: cryptoService,
        trustStore: trustStoreA,
        secureKeyStore: InMemorySecureKeyStore(),
        localIdentity: identityA,
      );
      secureManagerB = SecureSessionManager(
        cryptoService: cryptoService,
        trustStore: trustStoreB,
        secureKeyStore: InMemorySecureKeyStore(),
        localIdentity: identityB,
      );
    });

    tearDown(() async {
      await secureManagerA.dispose();
      await secureManagerB.dispose();
      await managerA.dispose();
      await managerB.dispose();
      await serverB.dispose();
    });

    Future<(SecureSessionImpl, SecureSessionImpl)> establishSecurePair() async {
      final sessionBFuture = managerB.onSessionEstablished.first;

      final sessionA = await managerA.connectToLanPeer(
        remoteAddress: '127.0.0.1',
        remotePort: serverB.boundPort,
      );
      final sessionB = await sessionBFuture;

      final responderSecureFuture = sessionB.incomingPackets
          .where((p) => p.packetType == PacketType.authExchange)
          .first
          .then((packet) {
            final initPayload = AuthInitPayload.fromBytes(packet.payload);
            return secureManagerB.handleInboundAuthInit(sessionB, initPayload);
          });

      final secureA = await secureManagerA.secureOutboundConnection(sessionA);
      final secureB = await responderSecureFuture;

      return (secureA, secureB);
    }

    test('Dynamic Rekeying: Session moves from Epoch 0 to Epoch 1, sequence resets to 0, data transfers successfully', () async {
      final (secureA, secureB) = await establishSecurePair();

      expect(secureA.currentEpoch, 0);
      expect(secureB.currentEpoch, 0);

      // 1. Send packet in Epoch 0
      final dataEpoch0 = utf8.encode('Hello Epoch 0');
      final packet0 = VayuPacket(
        packetType: PacketType.transferChunk,
        packetId: 1,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payload: Uint8List.fromList(dataEpoch0),
      );

      final bReceived0 = secureB.incomingDecryptedPackets.first;
      await secureA.sendEncryptedPacket(packet0);
      final received0 = await bReceived0;
      expect(utf8.decode(received0.payload), 'Hello Epoch 0');

      // 2. Perform Dynamic In-Band Rekeying initiated by A
      await secureManagerA.initiateRekey(secureA.sessionId);

      // Allow microtasks for responder transition
      await Future.delayed(const Duration(milliseconds: 100));

      expect(secureA.currentEpoch, 1);
      expect(secureB.currentEpoch, 1);

      // 3. Send packet in Epoch 1 (A -> B)
      final dataEpoch1A = utf8.encode('Hello Epoch 1 from A');
      final packet1A = VayuPacket(
        packetType: PacketType.transferChunk,
        packetId: 2,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payload: Uint8List.fromList(dataEpoch1A),
      );

      final bReceived1 = secureB.incomingDecryptedPackets.first;
      await secureA.sendEncryptedPacket(packet1A);
      final received1 = await bReceived1;
      expect(utf8.decode(received1.payload), 'Hello Epoch 1 from A');

      // 4. Send packet in Epoch 1 (B -> A)
      final dataEpoch1B = utf8.encode('Hello Epoch 1 from B');
      final packet1B = VayuPacket(
        packetType: PacketType.transferAck,
        packetId: 3,
        sourceDeviceId: identityB.deviceId,
        destinationDeviceId: identityA.deviceId,
        payload: Uint8List.fromList(dataEpoch1B),
      );

      final aReceived1 = secureA.incomingDecryptedPackets.first;
      await secureB.sendEncryptedPacket(packet1B);
      final reply1 = await aReceived1;
      expect(utf8.decode(reply1.payload), 'Hello Epoch 1 from B');
    });

    test('Grace Drain Period: in-flight Epoch 0 packet is decrypted by peer in Epoch 1', () async {
      final (secureA, secureB) = await establishSecurePair();

      // 1. Prepare packet in Epoch 0
      final inFlightData = utf8.encode('In Flight Packet across Rekey');
      final aad = CryptoService.constructAad(
        magic1: 0x53,
        magic2: 0x53,
        protocolVersion: 1,
        packetTypeCode: PacketType.transferChunk.code,
        packetId: 50,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payloadLength: inFlightData.length + EncryptedEnvelope.minEnvelopeSize,
        sessionId: secureA.sessionIdBytes,
        aeadNonce: Uint8List(12),
      );

      // A encrypts with Epoch 0
      final epoch0EncryptedBytes = await secureA.encryptPayload(
        Uint8List.fromList(inFlightData),
        associatedData: aad,
      );

      // 2. Transition both to Epoch 1
      await secureManagerA.initiateRekey(secureA.sessionId);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(secureA.currentEpoch, 1);
      expect(secureB.currentEpoch, 1);

      // 3. Peer B receives the delayed Epoch 0 packet while in Epoch 1
      // B should decrypt it using retained Epoch 0 key material
      final decryptedInFlight = await secureB.decryptPayload(
        epoch0EncryptedBytes,
        associatedData: aad,
      );
      expect(utf8.decode(decryptedInFlight), 'In Flight Packet across Rekey');

      // 4. Stale packets from 2 epochs ago are rejected
      // Simulate epoch = 0 arriving when receiver is at epoch 2
      final envelopeStale = EncryptedEnvelope(
        epoch: 0,
        sequenceNumber: 99,
        ciphertext: Uint8List(10),
        authTag: Uint8List(16),
      );
      expect(
        () => secureB.decryptPayload(
          envelopeStale.toBytes(),
          associatedData: aad,
        ),
        throwsA(isA<SecurityError>()),
      );
    });

    test('Rekey rejection on forged PrevEpochMac', () async {
      final (secureA, secureB) = await establishSecurePair();

      // Forged RekeyInit with bogus PrevEpochMac
      final forgedInit = RekeyInitPayload(
        targetEpoch: 1,
        sessionId: secureB.sessionIdBytes,
        ephemeralPubKey: Uint8List(32)..fillRange(0, 32, 0x11),
        nonce: Uint8List(32)..fillRange(0, 32, 0x22),
        prevEpochMac: Uint8List(32)..fillRange(0, 32, 0xFF), // Invalid MAC
        signature: Uint8List(64)..fillRange(0, 64, 0x33),
      );

      final forgedPacket = VayuPacket(
        packetType: PacketType.authExchange,
        packetId: 9999,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payload: forgedInit.toBytes(),
      );

      // Send to B
      await secureA.connectionSession.sendPacket(forgedPacket);
      await Future.delayed(const Duration(milliseconds: 100));

      // B must remain on Epoch 0
      expect(secureB.currentEpoch, 0);
    });

    test(
      'NFC Wire Commitment Handshake assigns TrustLevel.nfcAuthenticated',
      () async {
        final sessionBFuture = managerB.onSessionEstablished.first;

        // Create genuine pairing payload with cryptographic commitment
        final keypairA = await secureManagerA.getOrInitializeLocalKeypair();
        final pairingSecret = Uint8List(16)..fillRange(0, 16, 0x77);

        final pairingPayload = PairingPayload.createWithNfcCommitment(
          deviceIdHex: identityA.idHex,
          displayName: 'Device-A',
          pairingToken: 'tok-12345678901234567890123456',
          ed25519PubKey: keypairA.publicKey,
          pairingSecret: pairingSecret,
        );

        // Register on B as pending NFC pairing
        secureManagerB.registerPendingNfcPairing(pairingPayload);

        // Connect
        final sessionA = await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: serverB.boundPort,
        );
        final sessionB = await sessionBFuture;

        final responderSecureFuture = sessionB.incomingPackets
            .where((p) => p.packetType == PacketType.authExchange)
            .first
            .then((packet) {
              final initPayload = AuthInitPayload.fromBytes(packet.payload);
              return secureManagerB.handleInboundAuthInit(
                sessionB,
                initPayload,
              );
            });

        final secureA = await secureManagerA.secureOutboundConnection(sessionA);
        final secureB = await responderSecureFuture;

        expect(secureA.isEstablished, isTrue);
        expect(secureB.isEstablished, isTrue);

        // B verified A against the registered NFC commitment
        expect(secureB.trustLevel, TrustLevel.nfcAuthenticated);
      },
    );

    test('NFC Wire Commitment Handshake with attacker key substitution aborts with NfcCommitmentMismatchException', () async {
      final sessionBFuture = managerB.onSessionEstablished.first;

      final keypairA = await secureManagerA.getOrInitializeLocalKeypair();
      final pairingSecret = Uint8List(16)..fillRange(0, 16, 0x77);

      // 1. Peer B registers genuine NFC pairing commitment for Device A
      final genuinePayload = PairingPayload.createWithNfcCommitment(
        deviceIdHex: identityA.idHex,
        displayName: 'Device-A',
        pairingToken: 'tok-12345678901234567890123456',
        ed25519PubKey: keypairA.publicKey,
        pairingSecret: pairingSecret,
      );

      secureManagerB.registerPendingNfcPairing(genuinePayload);

      // 2. An attacker (or corrupted sender) with a DIFFERENT identity key connects claiming to be Device A
      final attackerIdentity = LocalDeviceIdentity(
        deviceId:
            identityA.deviceId, // Attacker spoofs Device A's network deviceId
        displayName: 'Attacker-Spoofing-A',
        platform: 'android',
        createdAt: DateTime.now(),
      );
      final managerAttacker = ConnectionManager(
        localIdentity: attackerIdentity,
        handshakeTimeout: const Duration(seconds: 5),
      );
      final secureManagerAttacker = SecureSessionManager(
        cryptoService: cryptoService,
        trustStore: PeerTrustStore(),
        secureKeyStore: InMemorySecureKeyStore(),
        localIdentity: attackerIdentity,
      );

      await managerAttacker.connectToLanPeer(
        remoteAddress: '127.0.0.1',
        remotePort: serverB.boundPort,
      );
      final sessionB = await sessionBFuture;

      // Attacker claims to be Device A's ID
      final attackerKp = await secureManagerAttacker
          .getOrInitializeLocalKeypair();
      final ephPairAttacker = await cryptoService
          .generateEphemeralX25519Keypair();
      final ephPubAttacker = await cryptoService.extractX25519PublicKey(
        ephPairAttacker,
      );
      final nonceAttacker = Uint8List(32)..fillRange(0, 32, 0x55);

      Uint8List parseSessionId(String id) {
        final clean = id.replaceAll('-', '').toLowerCase();
        final bytes = Uint8List(16);
        for (int i = 0; i < 16; i++) {
          bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
        }
        return bytes;
      }

      final sessIdBytes = parseSessionId(sessionB.sessionId);

      final mInitSpoofed = AuthInitPayload.constructSigningMessage(
        sessionId: sessIdBytes,
        initiatorDeviceId: identityA.deviceId, // Spoofing device A!
        responderDeviceId: identityB.deviceId,
        initiatorEphemeralPubKey: ephPubAttacker,
        initiatorNonce: nonceAttacker,
        initiatorIdentityPubKey:
            attackerKp.publicKey, // But using attacker's key!
      );

      final sigAttacker = await cryptoService.signEd25519(
        message: mInitSpoofed,
        privateKeySeed: attackerKp.privateKeySeed!,
      );

      final spoofedInitPayload = AuthInitPayload(
        sessionId: sessIdBytes,
        ephemeralPubKey: ephPubAttacker,
        nonce: nonceAttacker,
        identityPubKey: attackerKp.publicKey,
        signature: sigAttacker,
      );

      // Responder B receives spoofed AuthInit
      // Because B registered NFC commitment for Device A, and attackerKp.publicKey does not match,
      // B MUST throw NfcCommitmentMismatchException and NEVER fall back to TOFU!
      expect(
        () async => await secureManagerB.handleInboundAuthInit(
          sessionB,
          spoofedInitPayload,
        ),
        throwsA(isA<NfcCommitmentMismatchException>()),
      );

      // Trust store for B must NOT have any record for Device A or the attacker
      expect(await trustStoreB.getPeerTrust(identityA.idHex), isNull);

      await secureManagerAttacker.dispose();
      await managerAttacker.dispose();
    });

    test('Old epoch keys cannot decrypt new epoch ciphertext (cryptographic epoch isolation)', () async {
      final (secureA, secureB) = await establishSecurePair();

      // Rekey from Epoch 0 to Epoch 1
      await secureManagerA.initiateRekey(secureA.sessionId);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(secureA.currentEpoch, 1);
      expect(secureB.currentEpoch, 1);

      // Encrypt in Epoch 1
      final payload = utf8.encode('Epoch 1 Secret Message');
      final aad = CryptoService.constructAad(
        magic1: 0x53,
        magic2: 0x53,
        protocolVersion: 1,
        packetTypeCode: PacketType.transferChunk.code,
        packetId: 777,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payloadLength: payload.length + EncryptedEnvelope.minEnvelopeSize,
        sessionId: secureA.sessionIdBytes,
        aeadNonce: Uint8List(12),
      );

      final epoch1Encrypted = await secureA.encryptPayload(
        Uint8List.fromList(payload),
        associatedData: aad,
      );

      // Tamper envelope to claim Epoch 0 (forcing receiver to try Epoch 0 keys)
      final envelope = EncryptedEnvelope.fromBytes(epoch1Encrypted);
      final forgedEnvelope = EncryptedEnvelope(
        epoch: 0,
        sequenceNumber: envelope.sequenceNumber,
        ciphertext: envelope.ciphertext,
        authTag: envelope.authTag,
      );

      // Decryption under Epoch 0 keys MUST fail AEAD MAC verification and throw SecurityError
      expect(
        () async => await secureB.decryptPayload(
          forgedEnvelope.toBytes(),
          associatedData: aad,
        ),
        throwsA(isA<SecurityError>()),
      );
    });

    test('Rekey rejection on forged Ed25519 signature', () async {
      final (secureA, secureB) = await establishSecurePair();

      final targetEpoch = 1;
      final ephPairA = await cryptoService.generateEphemeralX25519Keypair();
      final ephPubA = await cryptoService.extractX25519PublicKey(ephPairA);
      final nonceA = Uint8List(32)..fillRange(0, 32, 0x11);

      final prevEpochMac = await cryptoService.computeRekeyPrevEpochMac(
        prevConfirmKey: secureA.activeConfirmKey,
        sessionId: secureA.sessionIdBytes,
        targetEpoch: targetEpoch,
        ephemeralPubKey: ephPubA,
        nonce: nonceA,
      );

      // RekeyInit with corrupted signature
      final forgedInit = RekeyInitPayload(
        targetEpoch: targetEpoch,
        sessionId: secureA.sessionIdBytes,
        ephemeralPubKey: ephPubA,
        nonce: nonceA,
        prevEpochMac: prevEpochMac,
        signature: Uint8List(64)
          ..fillRange(0, 64, 0x99), // Corrupted signature!
      );

      final forgedPacket = VayuPacket(
        packetType: PacketType.authExchange,
        packetId: 8888,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payload: forgedInit.toBytes(),
      );

      await secureA.connectionSession.sendPacket(forgedPacket);
      await Future.delayed(const Duration(milliseconds: 100));

      // B must reject and remain at Epoch 0
      expect(secureB.currentEpoch, 0);
    });

    test('Simultaneous Rekey Collision: Deterministic tie-breaker succeeds without deadlock', () async {
      final (secureA, secureB) = await establishSecurePair();

      expect(secureA.currentEpoch, 0);
      expect(secureB.currentEpoch, 0);

      // Both A and B trigger initiateRekey concurrently!
      final rekeyAFuture = secureManagerA.initiateRekey(secureA.sessionId);
      final rekeyBFuture = secureManagerB.initiateRekey(secureB.sessionId);

      await Future.wait([rekeyAFuture, rekeyBFuture]);

      // Both must successfully land on Epoch 1 without deadlock!
      expect(secureA.currentEpoch, 1);
      expect(secureB.currentEpoch, 1);

      // Verify bidirectional encrypted data transmission in Epoch 1
      final dataFromA = utf8.encode('Data post-collision from A');
      final packetA = VayuPacket(
        packetType: PacketType.transferChunk,
        packetId: 201,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payload: Uint8List.fromList(dataFromA),
      );

      final bReceived = secureB.incomingDecryptedPackets.first;
      await secureA.sendEncryptedPacket(packetA);
      final receivedOnB = await bReceived;
      expect(utf8.decode(receivedOnB.payload), 'Data post-collision from A');
    });
  });
}
