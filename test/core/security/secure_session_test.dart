import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/errors/app_error.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/security/auth_exchange_payload.dart';
import 'package:vayu/domain/security/encrypted_envelope.dart';
import 'package:vayu/domain/security/trust_level.dart';

void main() {
  group('SecureSession & SecureSessionManager Real Loopback Tests', () {
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
        displayName: 'Phone-A',
        platform: 'android',
      );
      identityB = LocalDeviceIdentity.generate(
        displayName: 'Laptop-B',
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

    test('3-Way Authenticated Key Exchange negotiates secure session and matching SAS', () async {
      final sessionBFuture = managerB.onSessionEstablished.first;

      // 1. Establish transport connection (SessionState.connected)
      final sessionA = await managerA.connectToLanPeer(
        remoteAddress: '127.0.0.1',
        remotePort: serverB.boundPort,
      );
      final sessionB = await sessionBFuture;

      expect(sessionA.state, SessionState.connected);
      expect(sessionB.state, SessionState.connected);

      // 2. Set up Responder listener for AuthInit
      final responderSecureFuture = sessionB.incomingPackets
          .where((p) => p.packetType == PacketType.authExchange)
          .first
          .then((packet) {
            final initPayload = AuthInitPayload.fromBytes(packet.payload);
            return secureManagerB.handleInboundAuthInit(sessionB, initPayload);
          });

      // 3. Initiator starts 3-way authenticated exchange
      final secureA = await secureManagerA.secureOutboundConnection(sessionA);
      final secureB = await responderSecureFuture;

      // 4. Verify both are secured
      expect(secureA.isEstablished, isTrue);
      expect(secureB.isEstablished, isTrue);
      expect(sessionA.state, SessionState.secured);
      expect(sessionB.state, SessionState.secured);

      // 5. Verify SAS match (6-digit numeric and 4-word biometric strings match exactly)
      expect(secureA.sas.numeric, equals(secureB.sas.numeric));
      expect(secureA.sas.words, equals(secureB.sas.words));
      expect(secureA.trustLevel, equals(TrustLevel.unverifiedTOFU));
      expect(secureB.trustLevel, equals(TrustLevel.unverifiedTOFU));
    });

    test(
      'End-to-End Encrypted Application Packet Transfer (A -> B and B -> A)',
      () async {
        final sessionBFuture = managerB.onSessionEstablished.first;

        final sessionA = await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: serverB.boundPort,
        );
        final sessionB = await sessionBFuture;

        final responderSecureFuture = sessionB.incomingPackets
            .where((p) => p.packetType == PacketType.authExchange)
            .first
            .then(
              (packet) => secureManagerB.handleInboundAuthInit(
                sessionB,
                AuthInitPayload.fromBytes(packet.payload),
              ),
            );

        final secureA = await secureManagerA.secureOutboundConnection(sessionA);
        final secureB = await responderSecureFuture;

        // Set up listener on B for decrypted application packets
        final bReceivedPacketFuture = secureB.incomingDecryptedPackets.first;

        // Initiator A sends encrypted packet (e.g. transferChunk)
        final secretPayloadA = utf8.encode(
          'Super Confidential Document Chunk 001',
        );
        final packetFromA = VayuPacket(
          packetType: PacketType.transferChunk,
          packetId: 101,
          sourceDeviceId: identityA.deviceId,
          destinationDeviceId: identityB.deviceId,
          payload: Uint8List.fromList(secretPayloadA),
        );

        await secureA.sendEncryptedPacket(packetFromA);

        // B receives and decrypts
        final decryptedOnB = await bReceivedPacketFuture;
        expect(decryptedOnB.packetType, PacketType.transferChunk);
        expect(decryptedOnB.packetId, 101);
        expect(
          utf8.decode(decryptedOnB.payload),
          'Super Confidential Document Chunk 001',
        );

        // Now B replies with encrypted packet to A
        final aReceivedPacketFuture = secureA.incomingDecryptedPackets.first;

        final secretReplyB = utf8.encode('Chunk 001 Acknowledged and Verified');
        final replyFromB = VayuPacket(
          packetType: PacketType.transferAck,
          packetId: 102,
          sourceDeviceId: identityB.deviceId,
          destinationDeviceId: identityA.deviceId,
          payload: Uint8List.fromList(secretReplyB),
        );

        await secureB.sendEncryptedPacket(replyFromB);

        final decryptedOnA = await aReceivedPacketFuture;
        expect(decryptedOnA.packetType, PacketType.transferAck);
        expect(decryptedOnA.packetId, 102);
        expect(
          utf8.decode(decryptedOnA.payload),
          'Chunk 001 Acknowledged and Verified',
        );
      },
    );

    test('Replay protection rejects duplicate sequence numbers', () async {
      final sessionBFuture = managerB.onSessionEstablished.first;
      final sessionA = await managerA.connectToLanPeer(
        remoteAddress: '127.0.0.1',
        remotePort: serverB.boundPort,
      );
      final sessionB = await sessionBFuture;

      final responderSecureFuture = sessionB.incomingPackets
          .where((p) => p.packetType == PacketType.authExchange)
          .first
          .then(
            (packet) => secureManagerB.handleInboundAuthInit(
              sessionB,
              AuthInitPayload.fromBytes(packet.payload),
            ),
          );

      final secureA = await secureManagerA.secureOutboundConnection(sessionA);
      final secureB = await responderSecureFuture;

      final payload = Uint8List.fromList([1, 2, 3, 4]);
      final nonce = Uint8List(12);
      final aad = CryptoService.constructAad(
        magic1: 0x53,
        magic2: 0x53,
        protocolVersion: 1,
        packetTypeCode: 0x11,
        packetId: 1,
        sourceDeviceId: identityA.deviceId,
        destinationDeviceId: identityB.deviceId,
        payloadLength: payload.length + EncryptedEnvelope.minEnvelopeSize,
        sessionId: Uint8List(16),
        aeadNonce: nonce,
      );

      // A encrypts payload (sequence 0)
      final encryptedBytes = await secureA.encryptPayload(
        payload,
        associatedData: aad,
      );

      // B decrypts sequence 0 successfully
      final decrypted1 = await secureB.decryptPayload(
        encryptedBytes,
        associatedData: aad,
      );
      expect(decrypted1, equals(payload));

      // B attempts to decrypt identical sequence 0 again -> must throw replay error
      expect(
        () async =>
            await secureB.decryptPayload(encryptedBytes, associatedData: aad),
        throwsA(isA<SecurityError>()),
      );
    });

    test('terminate wipes keys and transitions session state', () async {
      final sessionBFuture = managerB.onSessionEstablished.first;
      final sessionA = await managerA.connectToLanPeer(
        remoteAddress: '127.0.0.1',
        remotePort: serverB.boundPort,
      );
      final sessionB = await sessionBFuture;

      final responderSecureFuture = sessionB.incomingPackets
          .where((p) => p.packetType == PacketType.authExchange)
          .first
          .then(
            (packet) => secureManagerB.handleInboundAuthInit(
              sessionB,
              AuthInitPayload.fromBytes(packet.payload),
            ),
          );

      final secureA = await secureManagerA.secureOutboundConnection(sessionA);
      await responderSecureFuture;

      expect(secureA.isEstablished, isTrue);

      await secureA.terminate();
      expect(secureA.isEstablished, isFalse);

      // Cannot encrypt after termination
      expect(
        () async => await secureA.encryptPayload(
          Uint8List(5),
          associatedData: Uint8List(76),
        ),
        throwsStateError,
      );
    });

    test(
      'Regression Issue 1: Outbound elevation is single authoritative path preserving parameters',
      () async {
        // Attach managers so responder auto-listens, and initiator awaits caller elevation
        secureManagerA.attachToConnectionManager(managerA);
        secureManagerB.attachToConnectionManager(managerB);

        // Connect transport
        final sessionA = await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: serverB.boundPort,
        );

        // Initiator authoritatively elevates with custom timeout and credentials
        final secureA = await secureManagerA.secureOutboundConnection(
          sessionA,
          timeout: const Duration(seconds: 8),
        );

        expect(secureA.isEstablished, isTrue);
        expect(secureManagerA.activeSessions.contains(secureA), isTrue);

        // Calling secureOutboundConnection a second time returns cached established session without competing handshakes
        final secureA2 = await secureManagerA.secureOutboundConnection(sessionA);
        expect(identical(secureA, secureA2), isTrue);
      },
    );
  });
}
