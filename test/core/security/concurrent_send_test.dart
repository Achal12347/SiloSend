import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/security/encrypted_envelope.dart';

/// Concurrent sends on one secure session (an ACK and a retransmit, or two
/// transfers) must each get their own sequence number. Reserving it after the
/// encryption await reused the AES-GCM nonce, and the receiver dropped the
/// second packet as a replay.
void main() {
  late LanConnectionServer server;
  late ConnectionManager managerA;
  late ConnectionManager managerB;
  late SecureSessionManager secureA;
  late SecureSessionManager secureB;
  late SecureSessionImpl sessionA;
  late SecureSessionImpl sessionB;
  late LocalDeviceIdentity a;
  late LocalDeviceIdentity b;

  setUp(() async {
    a = LocalDeviceIdentity.generate(displayName: 'A', platform: 'android');
    b = LocalDeviceIdentity.generate(displayName: 'B', platform: 'android');
    server = LanConnectionServer(requestedPort: 0);
    await server.start();
    managerA = ConnectionManager(localIdentity: a);
    managerB = ConnectionManager(localIdentity: b)..registerLanServer(server);
    final crypto = CryptoService();
    secureA = SecureSessionManager(
      cryptoService: crypto,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: a,
    );
    secureB = SecureSessionManager(
      cryptoService: crypto,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: b,
    );
    secureB.attachToConnectionManager(managerB);
    final securedB = secureB.secureSessions.first;
    final raw = await managerA.connectToLanPeer(
      remoteAddress: '127.0.0.1',
      remotePort: server.boundPort,
    );
    sessionA = await secureA.secureOutboundConnection(raw);
    sessionB = await securedB;
  });

  tearDown(() async {
    await secureA.dispose();
    await secureB.dispose();
    await managerA.dispose();
    await managerB.dispose();
    await server.stop();
  });

  VayuPacket packet(int i) => VayuPacket(
    packetType: PacketType.transferAck,
    packetId: i,
    sourceDeviceId: a.deviceId,
    destinationDeviceId: b.deviceId,
    payload: Uint8List.fromList([i & 0xff, (i >> 8) & 0xff]),
  );

  test('concurrent sends all arrive, in order, with distinct nonces', () async {
    const count = 200;
    final received = <int>[];
    final errors = <Object>[];
    final allArrived = Completer<void>();
    final sub = sessionB.incomingDecryptedPackets.listen((p) {
      received.add(p.packetId);
      if (received.length == count) allArrived.complete();
    }, onError: errors.add);
    final sequences = <int>{};
    final rawSub = sessionB.connectionSession.incomingPackets.listen((p) {
      if (p.packetType == PacketType.transferAck) {
        sequences.add(EncryptedEnvelope.fromBytes(p.payload).sequenceNumber);
      }
    });

    // Nothing awaited between calls: every send is in flight at once.
    await Future.wait([
      for (var i = 0; i < count; i++) sessionA.sendEncryptedPacket(packet(i)),
    ]);
    await allArrived.future.timeout(const Duration(seconds: 10));

    expect(errors, isEmpty);
    expect(received, List<int>.generate(count, (i) => i));
    expect(sequences.length, count);
    expect(sessionA.txSequence, count);
    await sub.cancel();
    await rawSub.cancel();
  });
}
