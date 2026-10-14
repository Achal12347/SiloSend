import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

import '../../ui/home/vayu_home_page_test.dart' show MockDiscoveryService;

class _FakeHotspot implements LocalHotspotService {
  bool hosting = false;
  bool joinResult = true;
  final List<String> calls = [];

  @override
  bool get isHosting => hosting;

  @override
  Future<HotspotStartResult> start() async {
    calls.add('start');
    hosting = true;
    return const HotspotStartResult.success(
      HotspotCredentials(
        ssid: 'AndroidShare_1234',
        passphrase: 'p4ssphrase',
        hostAddress: '127.0.0.1',
      ),
    );
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    hosting = false;
  }

  @override
  Future<bool> join({required String ssid, required String passphrase}) async {
    calls.add('join:$ssid:$passphrase');
    return joinResult;
  }

  @override
  Future<void> leave() async => calls.add('leave');
}

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

PairingCoordinator _withHotspot(
  AppContainer c,
  _FakeHotspot hotspot, {
  required StreamController<Object?> sessions,
  required int Function() count,
}) {
  return PairingCoordinator(
    identity: () => c.identity,
    lanPort: () => c.lanServer?.boundPort,
    localPublicKeyHex: () => c.localKeypair?.publicKeyHex,
    supportsBle: () => false,
    discoveryCoordinator: c.discoveryCoordinator,
    secureSessionManager: c.secureSessionManager,
    transportSelector: c.transportSelector,
    fileSharingCoordinator: c.fileSharingCoordinator,
    hotspot: hotspot,
    activeSessionCount: count,
    sessionChanges: sessions.stream,
    hotspotIdleTimeout: const Duration(milliseconds: 50),
  );
}

void main() {
  late AppContainer host;
  late AppContainer joiner;

  setUp(() async {
    host = await _container('Host');
    joiner = await _container('Joiner');
  });

  tearDown(() async {
    await host.lanServer?.stop();
    await joiner.lanServer?.stop();
    host.dispose();
    joiner.dispose();
  });

  test('a code with hotspot details makes the joiner join that network first', () async {
    final hostHotspot = _FakeHotspot();
    final joinHotspot = _FakeHotspot();
    final sessions = StreamController<Object?>.broadcast();
    var count = 0;
    final hostPairing = _withHotspot(
      host,
      hostHotspot,
      sessions: sessions,
      count: () => count,
    );
    final joinPairing = _withHotspot(
      joiner,
      joinHotspot,
      sessions: sessions,
      count: () => count,
    );

    final started = await hostPairing.startHotspot();
    final payload = await hostPairing.buildLocalPayload(
      hotspotCredentials: started.credentials,
    );
    expect(payload.wifiSsid, 'AndroidShare_1234');
    expect(payload.lanAddress, '127.0.0.1');

    final peer = await joinPairing.join(payload);
    expect(peer.displayName, 'Host');
    expect(joinHotspot.calls.first, 'join:AndroidShare_1234:p4ssphrase');

    // No sessions remain: both sides release the network after the idle window.
    hostPairing.releaseHotspotWhenIdle();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(hostHotspot.calls, contains('stop'));
    expect(joinHotspot.calls, contains('leave'));
    await sessions.close();
  });

  test('an active session keeps the hotspot up', () async {
    final hotspot = _FakeHotspot();
    final sessions = StreamController<Object?>.broadcast();
    var count = 1;
    final pairing = _withHotspot(
      host,
      hotspot,
      sessions: sessions,
      count: () => count,
    );

    await pairing.startHotspot();
    pairing.releaseHotspotWhenIdle();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(hotspot.calls, isNot(contains('stop')));

    count = 0;
    sessions.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(hotspot.calls, contains('stop'));
    await sessions.close();
  });

  test('a declined join is reported with what to do next', () async {
    final hostPairing = _withHotspot(
      host,
      _FakeHotspot(),
      sessions: StreamController<Object?>.broadcast(),
      count: () => 0,
    );
    final joinHotspot = _FakeHotspot()..joinResult = false;
    final joinPairing = _withHotspot(
      joiner,
      joinHotspot,
      sessions: StreamController<Object?>.broadcast(),
      count: () => 0,
    );
    final started = await hostPairing.startHotspot();
    final payload = await hostPairing.buildLocalPayload(
      hotspotCredentials: started.credentials,
    );
    await expectLater(
      joinPairing.join(payload),
      throwsA(
        isA<PairingException>().having(
          (e) => e.message,
          'message',
          contains('Wi-Fi settings'),
        ),
      ),
    );
  });
}
