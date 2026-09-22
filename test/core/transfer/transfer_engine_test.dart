import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/connection/connection_manager.dart';
import 'package:silosend_datasharing_app/core/connection/lan_connection_server.dart';
import 'package:silosend_datasharing_app/core/contracts/transfer_contract.dart';
import 'package:silosend_datasharing_app/core/identity/identity_storage.dart';
import 'package:silosend_datasharing_app/core/security/crypto_service.dart';
import 'package:silosend_datasharing_app/core/security/peer_trust_store.dart';
import 'package:silosend_datasharing_app/core/security/secure_key_store.dart';
import 'package:silosend_datasharing_app/core/security/secure_session_impl.dart';
import 'package:silosend_datasharing_app/core/security/secure_session_manager.dart';
import 'package:silosend_datasharing_app/core/state/app_container.dart';
import 'package:silosend_datasharing_app/core/transfer/transfer_engine_impl.dart';
import 'package:silosend_datasharing_app/domain/identity/local_device_identity.dart';
import 'package:silosend_datasharing_app/domain/models/transfer_models.dart';
import 'package:silosend_datasharing_app/domain/protocol/packet_type.dart';
import 'package:silosend_datasharing_app/domain/security/auth_exchange_payload.dart';
import 'package:silosend_datasharing_app/domain/transfer/payload_source.dart';

void main() {
  group('Phase 7 TransferEngine Real SecureSession Loopback Tests', () {
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
    late TransferEngineImpl engineA;
    late TransferEngineImpl engineB;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync(
        'silosend_transfer_engine_test_',
      );

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

      engineA = TransferEngineImpl(
        localDeviceId: identityA.idHex,
        secureSessionManager: secureManagerA,
      );
      engineB = TransferEngineImpl(
        localDeviceId: identityB.idHex,
        secureSessionManager: secureManagerB,
      );
    });

    tearDown(() async {
      await engineA.dispose();
      await engineB.dispose();
      await secureManagerA.dispose();
      await secureManagerB.dispose();
      await managerA.dispose();
      await managerB.dispose();
      await serverB.stop();
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
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

    test('Loopback multi-chunk file transfer over encrypted SecureSession completes and verifies SHA-256', () async {
      await establishSecurePair();

      // Create test file (200 KB -> 4 chunks)
      final sourceFile = File('${tempDir.path}/alice_document.pdf');
      final totalBytes = 200 * 1024;
      final rawData = Uint8List.fromList(
        List.generate(totalBytes, (i) => (i * 7) % 256),
      );
      sourceFile.writeAsBytesSync(rawData);

      final source = FilePayloadSource(sourceFile);
      final sha256 = await source.computeSha256();

      final metadata = TransferMetadata(
        transferId: 'abcdef0123456789abcdef0123456789',
        fileName: 'alice_document.pdf',
        totalBytes: totalBytes,
        chunkSize: 64 * 1024,
        sha256Checksum: sha256,
        mimeType: 'application/pdf',
      );

      final saveDestinationPath = '${tempDir.path}/bob_received_document.pdf';

      // Set up Bob's listener for incoming request
      final bobRequestFuture = engineB.incomingTransferRequests.first;

      // Alice initiates transfer
      final aliceTask = await engineA.sendPayload(
        targetDeviceId: identityB.idHex,
        source: source,
        metadata: metadata,
      );

      // Bob receives offer and accepts
      final request = await bobRequestFuture;
      expect(request.metadata.fileName, equals('alice_document.pdf'));
      expect(request.metadata.totalBytes, equals(totalBytes));

      final bobTask = await request.accept(saveDestinationPath);

      // Wait for both to finish
      await Future.wait([aliceTask.done, bobTask.done]);

      expect(aliceTask.status, equals(TransferStatus.completed));
      expect(bobTask.status, equals(TransferStatus.completed));

      final savedFile = File(saveDestinationPath);
      expect(savedFile.existsSync(), isTrue);
      expect(savedFile.lengthSync(), equals(totalBytes));
      expect(savedFile.readAsBytesSync(), equals(rawData));

      await source.close();
    });

    test('Recipient decline cleanly terminates transfer with TransferCancelledException', () async {
      await establishSecurePair();

      final source = MemoryPayloadSource(Uint8List(100));
      final metadata = TransferMetadata(
        transferId: 'dddddddddddddddddddddddddddddddd',
        fileName: 'declined_file.bin',
        totalBytes: 100,
        sha256Checksum: await source.computeSha256(),
      );

      final bobRequestFuture = engineB.incomingTransferRequests.first;

      final aliceTask = await engineA.sendPayload(
        targetDeviceId: identityB.idHex,
        source: source,
        metadata: metadata,
      );

      final aliceDoneExpectation = expectLater(
        aliceTask.done,
        throwsA(isA<TransferCancelledException>()),
      );

      final request = await bobRequestFuture;
      await request.decline('User rejected transfer');

      await aliceDoneExpectation;
      expect(aliceTask.status, equals(TransferStatus.cancelled));
    });

    test(
      'Sender cancellation cleans up recipient temporary staging file',
      () async {
        await establishSecurePair();

        final source = MemoryPayloadSource(Uint8List(64 * 1024 * 5));
        final metadata = TransferMetadata(
          transferId: 'cccccccccccccccccccccccccccccccc',
          fileName: 'cancel_me.bin',
          totalBytes: 64 * 1024 * 5,
          sha256Checksum: await source.computeSha256(),
        );

        final bobRequestFuture = engineB.incomingTransferRequests.first;

        final aliceTask = await engineA.sendPayload(
          targetDeviceId: identityB.idHex,
          source: source,
          metadata: metadata,
        );

        final savePath = '${tempDir.path}/cancelled_target.bin';
        final request = await bobRequestFuture;
        final bobTask = await request.accept(savePath);

        final aliceDoneExpectation = expectLater(
          aliceTask.done,
          throwsA(isA<TransferCancelledException>()),
        );
        final bobDoneExpectation = expectLater(
          bobTask.done,
          throwsA(isA<TransferCancelledException>()),
        );

        // Alice cancels mid-transfer
        await aliceTask.cancel('User decided to stop');

        await aliceDoneExpectation;
        await bobDoneExpectation;

        expect(aliceTask.status, equals(TransferStatus.cancelled));
        expect(bobTask.status, equals(TransferStatus.cancelled));

        // Temporary staging file deleted
        final stagingFile = File('$savePath.silosend.tmp');
        expect(stagingFile.existsSync(), isFalse);
        expect(File(savePath).existsSync(), isFalse);
      },
    );

    test(
      'Zero-byte (empty) file transfer completes and verifies successfully',
      () async {
        await establishSecurePair();

        final emptySource = MemoryPayloadSource(Uint8List(0));
        final sha256 = await emptySource.computeSha256();

        final metadata = TransferMetadata(
          transferId: '00000000000000000000000000000000',
          fileName: 'empty.txt',
          totalBytes: 0,
          sha256Checksum: sha256,
        );

        final savePath = '${tempDir.path}/bob_empty.txt';
        final bobRequestFuture = engineB.incomingTransferRequests.first;

        final aliceTask = await engineA.sendPayload(
          targetDeviceId: identityB.idHex,
          source: emptySource,
          metadata: metadata,
        );

        final request = await bobRequestFuture;
        final bobTask = await request.accept(savePath);

        await Future.wait([aliceTask.done, bobTask.done]);

        expect(aliceTask.status, equals(TransferStatus.completed));
        expect(bobTask.status, equals(TransferStatus.completed));

        final savedFile = File(savePath);
        expect(savedFile.existsSync(), isTrue);
        expect(savedFile.lengthSync(), equals(0));
      },
    );

    test(
      'Concurrent multiplexed transfers run simultaneously without crosstalk',
      () async {
        await establishSecurePair();

        // Payload 1: 130 KB (3 chunks)
        final data1 = Uint8List.fromList(
          List.generate(130 * 1024, (i) => i % 255),
        );
        final source1 = MemoryPayloadSource(data1);
        final sha1 = await source1.computeSha256();
        final meta1 = TransferMetadata(
          transferId: '11111111111111111111111111111111',
          fileName: 'concurrent_1.bin',
          totalBytes: data1.length,
          sha256Checksum: sha1,
        );

        // Payload 2: 70 KB (2 chunks)
        final data2 = Uint8List.fromList(
          List.generate(70 * 1024, (i) => (i * 3) % 255),
        );
        final source2 = MemoryPayloadSource(data2);
        final sha2 = await source2.computeSha256();
        final meta2 = TransferMetadata(
          transferId: '22222222222222222222222222222222',
          fileName: 'concurrent_2.bin',
          totalBytes: data2.length,
          sha256Checksum: sha2,
        );

        final bobRequests = <IncomingTransferRequest>[];
        final reqSub = engineB.incomingTransferRequests.listen(bobRequests.add);

        final aliceTask1 = await engineA.sendPayload(
          targetDeviceId: identityB.idHex,
          source: source1,
          metadata: meta1,
        );
        final aliceTask2 = await engineA.sendPayload(
          targetDeviceId: identityB.idHex,
          source: source2,
          metadata: meta2,
        );

        // Wait for both requests to arrive at Bob
        while (bobRequests.length < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await reqSub.cancel();

        final savePath1 = '${tempDir.path}/bob_conc_1.bin';
        final savePath2 = '${tempDir.path}/bob_conc_2.bin';

        final req1 = bobRequests.firstWhere(
          (r) => r.transferId == meta1.transferId,
        );
        final req2 = bobRequests.firstWhere(
          (r) => r.transferId == meta2.transferId,
        );

        final bobTask1 = await req1.accept(savePath1);
        final bobTask2 = await req2.accept(savePath2);

        await Future.wait([
          aliceTask1.done,
          aliceTask2.done,
          bobTask1.done,
          bobTask2.done,
        ]);

        expect(aliceTask1.status, equals(TransferStatus.completed));
        expect(aliceTask2.status, equals(TransferStatus.completed));
        expect(bobTask1.status, equals(TransferStatus.completed));
        expect(bobTask2.status, equals(TransferStatus.completed));

        expect(File(savePath1).readAsBytesSync(), equals(data1));
        expect(File(savePath2).readAsBytesSync(), equals(data2));
      },
    );

    test(
      'Contact transfer carries PayloadType.contact and extraMetadata',
      () async {
        await establishSecurePair();

        final vcardBytes = Uint8List.fromList(
          utf8.encode(
            'BEGIN:VCARD\nVERSION:3.0\nFN:Alice Smith\nTEL:+1234567890\nEND:VCARD',
          ),
        );
        final source = MemoryPayloadSource(vcardBytes);
        final sha = await source.computeSha256();
        final extra = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);

        final metadata = TransferMetadata(
          transferId: '33333333333333333333333333333333',
          fileName: 'AliceSmith.vcf',
          totalBytes: vcardBytes.length,
          sha256Checksum: sha,
          mimeType: 'text/vcard',
          payloadType: PayloadType.contact,
          extraMetadata: extra,
        );

        final savePath = '${tempDir.path}/AliceSmith.vcf';
        final bobRequestFuture = engineB.incomingTransferRequests.first;

        final aliceTask = await engineA.sendPayload(
          targetDeviceId: identityB.idHex,
          source: source,
          metadata: metadata,
        );

        final request = await bobRequestFuture;
        expect(request.metadata.payloadType, equals(PayloadType.contact));
        expect(request.metadata.extraMetadata, equals(extra));

        final bobTask = await request.accept(savePath);

        await Future.wait([aliceTask.done, bobTask.done]);

        expect(aliceTask.status, equals(TransferStatus.completed));
        expect(bobTask.status, equals(TransferStatus.completed));
        expect(File(savePath).readAsBytesSync(), equals(vcardBytes));
      },
    );

    test('AppContainer exposes unified transferEngine and streams', () async {
      final container = AppContainer.standard(
        storage: InMemoryIdentityStorage(),
      );

      await container.initialize();

      expect(container.transferEngine, isNotNull);
      expect(container.incomingTransferRequests, isNotNull);
      expect(container.activeTransfers, isEmpty);

      container.dispose();
    });
  });
}
