import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/domain/security/trust_level.dart';

import '../../ui/home/vayu_home_page_test.dart' show MockDiscoveryService;

Future<AppContainer> _container(String name) async {
  final server = LanConnectionServer(requestedPort: 0);
  await server.start();
  final c = AppContainer.standard(
    storage: InMemoryIdentityStorage(
      LocalDeviceIdentity.generate(displayName: name, platform: 'android'),
    ),
    lanServer: server,
    discoveryCoordinator: DiscoveryCoordinator(
      services: [MockDiscoveryService(TransportType.lan)],
    ),
  );
  await c.initialize();
  return c;
}

void main() {
  late AppContainer shower;
  late AppContainer joiner;

  setUp(() async {
    shower = await _container('Shower');
    joiner = await _container('Joiner');
  });

  tearDown(() async {
    await shower.lanServer?.stop();
    await joiner.lanServer?.stop();
    shower.dispose();
    joiner.dispose();
  });

  test(
    'the shown pairing link carries an address, port and identity key',
    () async {
      final payload = await shower.pairingCoordinator.buildLocalPayload();
      expect(payload.lanPort, shower.lanServer!.boundPort);
      expect(payload.ed25519PubKeyHex, shower.localKeypair!.publicKeyHex);
      // Recomputed by the joiner; omitted to keep the QR code small.
      expect(payload.nfcCommitmentHex, isNull);

      final roundTrip = PairingPayload.fromUri(payload.toUri());
      expect(roundTrip.ed25519PubKeyHex, payload.ed25519PubKeyHex);
      expect(roundTrip.lanPort, payload.lanPort);
    },
  );

  test(
    'joining from a link connects securely and verifies the key out of band',
    () async {
      final shown = (await shower.pairingCoordinator.buildLocalPayload())
          // Loopback stands in for the Wi-Fi address on a test host.
          .copyWith(lanAddress: '127.0.0.1');

      final peer = await joiner.pairingCoordinator.joinFromText(
        shown.toUri().toString(),
      );

      expect(peer.displayName, 'Shower');
      expect(
        joiner.discoveredPeers.map((p) => p.deviceId),
        contains(shower.identity!.idHex),
      );
      final session = joiner.secureSessionManager.getSessionForPeer(
        shower.identity!.idHex,
      );
      expect(session, isNotNull);
      // Commitment matched: stronger than first-contact trust.
      expect(session!.trustLevel, TrustLevel.nfcAuthenticated);
    },
  );

  test(
    'a link without an address explains what to do instead of failing silently',
    () async {
      final shown = (await shower.pairingCoordinator.buildLocalPayload());
      final noAddress = PairingPayload(
        deviceIdHex: shown.deviceIdHex,
        displayName: shown.displayName,
        pairingToken: shown.pairingToken,
      );
      await expectLater(
        joiner.pairingCoordinator.join(noAddress),
        throwsA(
          isA<PairingException>().having(
            (e) => e.message,
            'message',
            contains('Not on the same Wi-Fi?'),
          ),
        ),
      );
    },
  );

  test('scanning your own code is rejected', () async {
    final own = (await shower.pairingCoordinator.buildLocalPayload()).copyWith(
      lanAddress: '127.0.0.1',
    );
    await expectLater(
      shower.pairingCoordinator.join(own),
      throwsA(isA<PairingException>()),
    );
  });
}
