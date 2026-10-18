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

/// A receive cut off by a dropped connection keeps its received prefix, and
/// the same file offered again continues from there.
void main() {
  test('an interrupted receive resumes from where it stopped', () async {
    final dir = Directory.systemTemp.createTempSync('vayu_resume_');
    final a = LocalDeviceIdentity.generate(
      displayName: 'A',
      platform: 'android',
    );
    final b = LocalDeviceIdentity.generate(
      displayName: 'B',
      platform: 'android',
    );
    final server = LanConnectionServer(requestedPort: 0);
    await server.start();
    final managerA = ConnectionManager(localIdentity: a);
    final managerB = ConnectionManager(localIdentity: b)
      ..registerLanServer(server);
    final crypto0 = CryptoService();
    final secureA = SecureSessionManager(
      cryptoService: crypto0,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: a,
    );
    final secureB = SecureSessionManager(
      cryptoService: crypto0,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: b,
    );
    secureB.attachToConnectionManager(managerB);
    final engineA = TransferEngineImpl(
      localDeviceId: a.idHex,
      secureSessionManager: secureA,
    );
    final engineB = TransferEngineImpl(
      localDeviceId: b.idHex,
      secureSessionManager: secureB,
    );

    const total = 32 * 1024 * 1024;
    const chunkSize = 256 * 1024;
    final random = Random(42);
    final data = Uint8List.fromList(
      List<int>.generate(total, (_) => random.nextInt(256)),
    );
    final sourceFile = File('${dir.path}/source.bin')..writeAsBytesSync(data);
    final expectedSha = crypto.sha256.convert(data).toString();
    final outPath = '${dir.path}/out.bin';

    final receivers = <TransferTask>[];
    final acceptSub = engineB.incomingTransferRequests.listen((request) async {
      receivers.add(await request.accept(outPath));
    });

    final sources = <FilePayloadSource>[];
    Future<TransferTask> send(String transferId) async {
      final source = FilePayloadSource(sourceFile);
      sources.add(source);
      return engineA.sendPayload(
        targetDeviceId: b.idHex,
        source: source,
        metadata: TransferMetadata(
          transferId: transferId,
          fileName: 'resume.bin',
          totalBytes: total,
          chunkSize: chunkSize,
          sha256Checksum: expectedSha,
        ),
      );
    }

    try {
      // 1. Start, then drop the connection about a quarter of the way in.
      final first = await secureA.secureOutboundConnection(
        await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: server.boundPort,
        ),
      );
      final sender1 = await send('a1' * 16);
      final cut = Completer<void>();
      sender1.progressStream.listen((p) {
        if (p.bytesTransferred >= total ~/ 4 && !cut.isCompleted) {
          cut.complete();
        }
      });
      await cut.future.timeout(const Duration(seconds: 20));
      await first.terminate();
      await expectLater(sender1.done, throwsA(anything));
      await expectLater(receivers.single.done, throwsA(anything));

      // The received prefix is kept, not deleted.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final kept = engineB.resumable.keptPaths;
      expect(kept, hasLength(1));
      expect(File(kept.single).lengthSync(), greaterThan(0));

      // 2. Reconnect and offer the same file again.
      await secureA.secureOutboundConnection(
        await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: server.boundPort,
        ),
      );
      final sender2 = await send('b2' * 16);
      var firstProgress = -1;
      sender2.progressStream.listen((p) {
        if (firstProgress < 0 && p.bytesTransferred > 0) {
          firstProgress = p.bytesTransferred;
        }
      });
      await sender2.done.timeout(const Duration(seconds: 60));
      await receivers.last.done;

      // It continued from the kept bytes instead of byte 0.
      expect(firstProgress, greaterThanOrEqualTo(total ~/ 8));
      expect(
        crypto.sha256.convert(File(outPath).readAsBytesSync()).toString(),
        expectedSha,
      );
      expect(engineB.resumable.keptPaths, isEmpty);
      expect(File('$outPath.vayu.tmp').existsSync(), isFalse);
    } finally {
      for (final source in sources) {
        await source.close();
      }
      await acceptSub.cancel();
      await engineA.dispose();
      await engineB.dispose();
      await secureA.dispose();
      await secureB.dispose();
      await managerA.dispose();
      await managerB.dispose();
      await server.stop();
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
