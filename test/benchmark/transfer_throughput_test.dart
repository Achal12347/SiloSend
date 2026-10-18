@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/security/aead_cipher.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transfer/transfer_engine_impl.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/security/auth_exchange_payload.dart';
import 'package:vayu/domain/transfer/payload_source.dart';

/// Loopback throughput benchmark over the real stack (TCP, handshake,
/// AES-GCM session, transfer engine, file source and destination).
///
/// It does not reproduce phone radios or the Android crypto/file bridges, so
/// absolute numbers are not phone numbers; it compares engine changes (chunk
/// size, window, ACK rate) against each other on one machine.
///
/// Run: VAYU_BENCH=1 flutter test test/benchmark/transfer_throughput_test.dart
/// Size in MB via VAYU_BENCH_MB (default 32). VAYU_BENCH_CIPHER=fast swaps the
/// pure-Dart AES (CPU-bound on desktop, not used on Android) for a trivial
/// test-only cipher with an async hop, so the numbers show pipeline overhead
/// (copies, CRC, framing, awaits) the way the hardware cipher would expose it.
void main() {
  final enabled = Platform.environment['VAYU_BENCH'] != null;
  final sizeMb =
      int.tryParse(Platform.environment['VAYU_BENCH_MB'] ?? '') ?? 32;

  for (final chunkKiB in [64, 256, 1024]) {
    test('throughput with $chunkKiB KiB chunks ($sizeMb MB)', () async {
      final result = await _runOnce(sizeMb * 1000 * 1000, chunkKiB * 1024);
      // ignore: avoid_print
      print('BENCH chunk=${chunkKiB}KiB: $result');
    }, skip: enabled ? false : 'set VAYU_BENCH=1 to run');
  }
}

Future<String> _runOnce(int totalBytes, int chunkSize) async {
  final dir = Directory.systemTemp.createTempSync('vayu_bench_');
  final a = LocalDeviceIdentity.generate(displayName: 'A', platform: 'android');
  final b = LocalDeviceIdentity.generate(displayName: 'B', platform: 'android');
  final server = LanConnectionServer(requestedPort: 0);
  await server.start();
  final managerA = ConnectionManager(localIdentity: a);
  final managerB = ConnectionManager(localIdentity: b)
    ..registerLanServer(server);
  final crypto = CryptoService(
    aead: Platform.environment['VAYU_BENCH_CIPHER'] == 'fast'
        ? _BenchCipher()
        : null,
  );
  final secureA = SecureSessionManager(
    cryptoService: crypto,
    trustStore: PeerTrustStore(),
    secureKeyStore: InMemorySecureKeyStore(),
    localIdentity: a,
  );
  final secureB = SecureSessionManager(
    cryptoService: crypto,
    trustStore: PeerTrustStore(),
    secureKeyStore: InMemorySecureKeyStore(),
    localIdentity: b,
  );
  final engineA = TransferEngineImpl(
    localDeviceId: a.idHex,
    secureSessionManager: secureA,
  );
  final engineB = TransferEngineImpl(
    localDeviceId: b.idHex,
    secureSessionManager: secureB,
  );

  try {
    final sessionBFuture = managerB.onSessionEstablished.first;
    final sessionA = await managerA.connectToLanPeer(
      remoteAddress: '127.0.0.1',
      remotePort: server.boundPort,
    );
    final sessionB = await sessionBFuture;
    final responder = sessionB.incomingPackets
        .where((p) => p.packetType == PacketType.authExchange)
        .first
        .then(
          (p) => secureB.handleInboundAuthInit(
            sessionB,
            AuthInitPayload.fromBytes(p.payload),
          ),
        );
    await secureA.secureOutboundConnection(sessionA);
    await responder;

    final sourceFile = File('${dir.path}/source.bin');
    final data = Uint8List(totalBytes);
    for (var i = 0; i < totalBytes; i += 4096) {
      data[i] = i & 0xff;
    }
    sourceFile.writeAsBytesSync(data);
    final source = FilePayloadSource(sourceFile);

    final clock = Stopwatch()..start();
    final metadata = TransferMetadata(
      transferId: 'beefbeefbeefbeefbeefbeefbeefbeef',
      fileName: 'bench.bin',
      totalBytes: totalBytes,
      chunkSize: chunkSize,
      sha256Checksum: await source.computeSha256(),
    );
    final hashTime = clock.elapsed;

    final requestFuture = engineB.incomingTransferRequests.first;
    final sendClock = Stopwatch()..start();
    final sender = await engineA.sendPayload(
      targetDeviceId: b.idHex,
      source: source,
      metadata: metadata,
    );
    final request = await requestFuture;
    final receiver = await request.accept('${dir.path}/out.bin');
    await Future.wait([sender.done, receiver.done]);
    sendClock.stop();
    await source.close();

    final mbps = totalBytes / 1e6 / (sendClock.elapsedMicroseconds / 1e6);
    return '${mbps.toStringAsFixed(1)} MB/s end-to-end '
        '(pre-hash ${hashTime.inMilliseconds} ms) | '
        '${engineA.statsLog.recent.first.summary()} | '
        '${engineB.statsLog.recent.first.summary()}';
  } finally {
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

/// Test-only stand-in for the platform cipher: copies the data (as the
/// channel does), crosses one event-loop turn, and uses a fixed tag. Never
/// secure; used only when VAYU_BENCH_CIPHER=fast.
class _BenchCipher implements AeadCipher {
  static final Uint8List _tag = Uint8List(16);

  @override
  Future<({Uint8List ciphertext, Uint8List authTag})> encrypt({
    required Uint8List plaintext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    final copy = Uint8List.fromList(plaintext);
    await Future<void>(() {});
    return (ciphertext: copy, authTag: Uint8List.fromList(_tag));
  }

  @override
  Future<Uint8List> decrypt({
    required Uint8List ciphertext,
    required Uint8List authTag,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    final copy = Uint8List.fromList(ciphertext);
    await Future<void>(() {});
    return copy;
  }
}
