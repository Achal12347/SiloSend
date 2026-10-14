import 'dart:typed_data';

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
import 'package:vayu/domain/transfer/payload_destination.dart';
import 'package:vayu/domain/transfer/payload_source.dart';

/// Guard for the handshake early-data race.
///
/// The initiator is secured one message before the responder. When its first
/// application packet arrives in the same socket read as AuthConfirm, both are
/// dispatched while the responder's AuthConfirm waiter is still subscribed, and
/// the offer used to be swallowed by that waiter. The race only showed under
/// CPU load (parallel test files), so this test is a smoke check of the flow,
/// not a deterministic reproduction.
void main() {
  test('transfer offers sent immediately after the handshake always reach the responder', () async {
    final identityA = LocalDeviceIdentity.generate(
      displayName: 'A',
      platform: 'android',
    );
    final identityB = LocalDeviceIdentity.generate(
      displayName: 'B',
      platform: 'android',
    );
    final serverB = LanConnectionServer(requestedPort: 0);
    await serverB.start();
    final managerA = ConnectionManager(localIdentity: identityA);
    final managerB = ConnectionManager(localIdentity: identityB);
    managerB.registerLanServer(serverB);

    final crypto = CryptoService();
    final secureA = SecureSessionManager(
      cryptoService: crypto,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: identityA,
    );
    final secureB = SecureSessionManager(
      cryptoService: crypto,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: identityB,
    );
    // The responder auto-handles AuthInit, as in the app.
    secureB.attachToConnectionManager(managerB);
    final engineA = TransferEngineImpl(
      localDeviceId: identityA.idHex,
      secureSessionManager: secureA,
    );
    final engineB = TransferEngineImpl(
      localDeviceId: identityB.idHex,
      secureSessionManager: secureB,
    );
    final acceptSub = engineB.incomingTransferRequests.listen((request) {
      request.acceptWithDestination(
        MemoryPayloadDestination(totalBytes: request.metadata.totalBytes),
      );
    });

    try {
      for (var round = 0; round < 25; round++) {
        final sessionA = await managerA.connectToLanPeer(
          remoteAddress: '127.0.0.1',
          remotePort: serverB.boundPort,
        );
        final secured = await secureA.secureOutboundConnection(sessionA);

        final data = Uint8List.fromList(List.generate(300, (i) => i & 0xff));
        final source = MemoryPayloadSource(data);
        final sender = await engineA.sendPayload(
          targetDeviceId: identityB.idHex,
          source: source,
          metadata: TransferMetadata(
            transferId: round.toRadixString(16).padLeft(32, 'e'),
            fileName: 'early_$round.bin',
            totalBytes: data.length,
            sha256Checksum: await source.computeSha256(),
          ),
        );

        await sender.done.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('round $round: offer was lost'),
        );
        expect(sender.status, TransferStatus.completed);
        await secured.terminate();
      }
    } finally {
      await acceptSub.cancel();
      await engineA.dispose();
      await engineB.dispose();
      await secureA.dispose();
      await secureB.dispose();
      await managerA.dispose();
      await managerB.dispose();
      await serverB.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
