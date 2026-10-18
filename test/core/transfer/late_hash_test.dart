import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transfer/transfer_engine_impl.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/transfer/payload_source.dart';

/// Two engines over loopback TCP with authenticated sessions.
class _Pair {
  final Directory dir = Directory.systemTemp.createTempSync('vayu_late_');
  final a = LocalDeviceIdentity.generate(displayName: 'A', platform: 'android');
  final b = LocalDeviceIdentity.generate(displayName: 'B', platform: 'android');
  final server = LanConnectionServer(requestedPort: 0);
  late final ConnectionManager managerA;
  late final ConnectionManager managerB;
  late final SecureSessionManager secureA;
  late final SecureSessionManager secureB;
  late final TransferEngineImpl engineA;
  late final TransferEngineImpl engineB;
  final sources = <FilePayloadSource>[];

  Future<void> start() async {
    await server.start();
    managerA = ConnectionManager(localIdentity: a);
    managerB = ConnectionManager(localIdentity: b)..registerLanServer(server);
    final cryptoService = CryptoService();
    secureA = SecureSessionManager(
      cryptoService: cryptoService,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: a,
    );
    secureB = SecureSessionManager(
      cryptoService: cryptoService,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: b,
    );
    secureB.attachToConnectionManager(managerB);
    engineA = TransferEngineImpl(
      localDeviceId: a.idHex,
      secureSessionManager: secureA,
    );
    engineB = TransferEngineImpl(
      localDeviceId: b.idHex,
      secureSessionManager: secureB,
    );
  }

  Future<dynamic> connect() async => secureA.secureOutboundConnection(
    await managerA.connectToLanPeer(
      remoteAddress: '127.0.0.1',
      remotePort: server.boundPort,
    ),
  );

  Future<TransferTask> send(
    File file,
    String transferId, {
    required int chunkSize,
    String? sha256,
    Future<String>? lateSha256,
  }) {
    final source = FilePayloadSource(file);
    sources.add(source);
    return engineA.sendPayload(
      targetDeviceId: b.idHex,
      source: source,
      metadata: TransferMetadata(
        transferId: transferId,
        fileName: 'late.bin',
        totalBytes: file.lengthSync(),
        chunkSize: chunkSize,
        sha256Checksum: sha256 ?? TransferMetadata.deferredSha256,
      ),
      lateSha256: lateSha256,
    );
  }

  Future<void> dispose() async {
    for (final source in sources) {
      await source.close();
    }
    await engineA.dispose();
    await engineB.dispose();
    await secureA.dispose();
    await secureB.dispose();
    await managerA.dispose();
    await managerB.dispose();
    await server.stop();
    dir.deleteSync(recursive: true);
  }
}

({File file, String sha}) _randomFile(Directory dir, int size) {
  final random = Random(7);
  final data = Uint8List.fromList(
    List<int>.generate(size, (_) => random.nextInt(256)),
  );
  return (
    file: File('${dir.path}/source.bin')..writeAsBytesSync(data),
    sha: crypto.sha256.convert(data).toString(),
  );
}

void main() {
  test('both builds advertise the late hash feature', () async {
    final pair = _Pair();
    await pair.start();
    try {
      await pair.connect();
      expect(pair.engineA.supportsLateHash(pair.b.idHex), isTrue);
    } finally {
      await pair.dispose();
    }
  });

  test('the offer arrives before hashing ends and the file verifies', () async {
    final pair = _Pair();
    await pair.start();
    try {
      final src = _randomFile(pair.dir, 3 * 1024 * 1024 + 123);
      final outPath = '${pair.dir.path}/out.bin';
      final hashing = Completer<String>();
      final offered = Completer<IncomingTransferRequest>();
      final sub = pair.engineB.incomingTransferRequests.listen(
        offered.complete,
      );
      await pair.connect();

      final sender = await pair.send(
        src.file,
        'aa' * 16,
        chunkSize: 256 * 1024,
        lateSha256: hashing.future,
      );
      // The receiver is asked while the sender is still "hashing".
      final request = await offered.future.timeout(const Duration(seconds: 5));
      expect(request.metadata.hashDeferred, isTrue);
      final receiver = await request.accept(outPath);

      // Every byte arrives, but nothing completes without the hash.
      for (
        var i = 0;
        i < 200 && receiver.status != TransferStatus.verifying;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(receiver.status, TransferStatus.verifying);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(receiver.status, TransferStatus.verifying);
      expect(File(outPath).existsSync(), isFalse);

      hashing.complete(src.sha);
      await sender.done.timeout(const Duration(seconds: 10));
      await receiver.done;
      expect(
        crypto.sha256.convert(File(outPath).readAsBytesSync()).toString(),
        src.sha,
      );
      await sub.cancel();
    } finally {
      await pair.dispose();
    }
  });

  test('a real transfer records every timing on both phones', () async {
    final pair = _Pair();
    await pair.start();
    try {
      // Above 4 MiB, so the receiver hashes while writing.
      final src = _randomFile(pair.dir, 6 * 1024 * 1024 + 5);
      final outPath = '${pair.dir.path}/timed.bin';
      final sub = pair.engineB.incomingTransferRequests.listen(
        (request) => request.accept(outPath),
      );
      await pair.connect();
      final sender = await pair.send(
        src.file,
        'cc' * 16,
        chunkSize: 1024 * 1024,
        sha256: src.sha,
      );
      await sender.done.timeout(const Duration(seconds: 20));
      for (var i = 0; i < 100 && pair.engineB.statsLog.recent.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final sent = pair.engineA.statsLog.recent.single;
      expect(sent.outbound, isTrue);
      expect(sent.succeeded, isTrue);
      expect(sent.crcTime, greaterThan(Duration.zero));
      expect(sent.cryptoTime, greaterThan(Duration.zero));

      final received = pair.engineB.statsLog.recent.single;
      expect(received.outbound, isFalse);
      expect(received.succeeded, isTrue);
      expect(received.bytes, src.file.lengthSync());
      expect(received.crcTime, greaterThan(Duration.zero));
      expect(received.cryptoTime, greaterThan(Duration.zero));
      expect(received.diskWriteTime, greaterThan(Duration.zero));
      // Disk and hash waiting are the two parts of the write time.
      expect(
        received.diskWriteTime + received.hashWaitTime,
        lessThanOrEqualTo(received.ioTime),
      );
      await sub.cancel();
    } finally {
      await pair.dispose();
    }
  });

  test('a late hash that does not match fails and leaves no file', () async {
    final pair = _Pair();
    await pair.start();
    try {
      final src = _randomFile(pair.dir, 1024 * 1024);
      final outPath = '${pair.dir.path}/out.bin';
      final sub = pair.engineB.incomingTransferRequests.listen((r) async {
        final task = await r.accept(outPath);
        await expectLater(
          task.done,
          throwsA(isA<TransferChecksumMismatchException>()),
        );
      });
      await pair.connect();

      final sender = await pair.send(
        src.file,
        'bb' * 16,
        chunkSize: 256 * 1024,
        lateSha256: Future.value('ab' * 32),
      );
      await expectLater(
        sender.done.timeout(const Duration(seconds: 10)),
        throwsA(isA<TransferException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File(outPath).existsSync(), isFalse);
      expect(File('$outPath.vayu.tmp').existsSync(), isFalse);
      await sub.cancel();
    } finally {
      await pair.dispose();
    }
  });

  test('a failed hash on the sender ends the transfer', () async {
    final pair = _Pair();
    await pair.start();
    try {
      final src = _randomFile(pair.dir, 1024 * 1024);
      final outPath = '${pair.dir.path}/out.bin';
      final receivers = <TransferTask>[];
      final sub = pair.engineB.incomingTransferRequests.listen((r) async {
        receivers.add(await r.accept(outPath));
      });
      await pair.connect();

      final sender = await pair.send(
        src.file,
        'cc' * 16,
        chunkSize: 256 * 1024,
        lateSha256: Future.error(const FileSystemException('gone')),
      );
      await expectLater(
        sender.done.timeout(const Duration(seconds: 10)),
        throwsA(isA<TransferSourceException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      for (final r in receivers) {
        await expectLater(r.done, throwsA(anything));
      }
      expect(File(outPath).existsSync(), isFalse);
      await sub.cancel();
    } finally {
      await pair.dispose();
    }
  });

  test(
    'accepting an offer the sender already cancelled fails at once',
    () async {
      final pair = _Pair();
      await pair.start();
      try {
        final src = _randomFile(pair.dir, 1024 * 1024);
        final outPath = '${pair.dir.path}/out.bin';
        final offered = Completer<IncomingTransferRequest>();
        final sub = pair.engineB.incomingTransferRequests.listen(
          offered.complete,
        );
        await pair.connect();

        final sender = await pair.send(
          src.file,
          'ee' * 16,
          chunkSize: 256 * 1024,
          lateSha256: Future.error(const FileSystemException('gone')),
        );
        final request = await offered.future.timeout(
          const Duration(seconds: 5),
        );
        await expectLater(sender.done, throwsA(isA<TransferSourceException>()));
        // Let the sender's cancel reach the receiver before it answers.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        await expectLater(
          request.accept(outPath),
          throwsA(isA<TransferCancelledException>()),
        );
        expect(File(outPath).existsSync(), isFalse);
        expect(File('$outPath.vayu.tmp').existsSync(), isFalse);
        await sub.cancel();
      } finally {
        await pair.dispose();
      }
    },
  );

  test('a late-hash receive cut off resumes when offered again', () async {
    final pair = _Pair();
    await pair.start();
    try {
      final src = _randomFile(pair.dir, 16 * 1024 * 1024);
      final outPath = '${pair.dir.path}/out.bin';
      final receivers = <TransferTask>[];
      final sub = pair.engineB.incomingTransferRequests.listen((r) async {
        receivers.add(await r.accept(outPath));
      });

      final first = await pair.connect();
      final sender1 = await pair.send(
        src.file,
        'd1' * 16,
        chunkSize: 256 * 1024,
        lateSha256: Completer<String>().future,
      );
      final cut = Completer<void>();
      sender1.progressStream.listen((p) {
        if (p.bytesTransferred >= src.file.lengthSync() ~/ 4 &&
            !cut.isCompleted) {
          cut.complete();
        }
      });
      await cut.future.timeout(const Duration(seconds: 20));
      await first.terminate();
      await expectLater(sender1.done, throwsA(anything));
      await expectLater(receivers.single.done, throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pair.engineB.resumable.keptPaths, hasLength(1));

      // Offered again, this time with the hash known up front.
      await pair.connect();
      final sender2 = await pair.send(
        src.file,
        'd2' * 16,
        chunkSize: 256 * 1024,
        sha256: src.sha,
      );
      var firstProgress = -1;
      sender2.progressStream.listen((p) {
        if (firstProgress < 0 && p.bytesTransferred > 0) {
          firstProgress = p.bytesTransferred;
        }
      });
      await sender2.done.timeout(const Duration(seconds: 30));
      await receivers.last.done;
      expect(firstProgress, greaterThanOrEqualTo(src.file.lengthSync() ~/ 8));
      expect(
        crypto.sha256.convert(File(outPath).readAsBytesSync()).toString(),
        src.sha,
      );
      await sub.cancel();
    } finally {
      await pair.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
