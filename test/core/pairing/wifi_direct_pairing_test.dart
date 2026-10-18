import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/core/pairing/wifi_direct_service.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';

import '../../ui/home/vayu_home_page_test.dart' show MockDiscoveryService;

class _FakeWifiDirect implements WifiDirectService {
  bool supported = true;
  bool hosting = false;
  HotspotStartError? createError;
  String? connectResult = '127.0.0.1';
  final List<String> calls = [];

  @override
  Future<bool> isSupported() async => supported;

  @override
  bool get isHosting => hosting;

  @override
  Future<({WifiDirectGroup? group, HotspotStartError? error})>
  createGroup() async {
    calls.add('create');
    final error = createError;
    if (error != null) return (group: null, error: error);
    hosting = true;
    return (
      group: const WifiDirectGroup(
        credentials: HotspotCredentials(
          ssid: 'DIRECT-vy-abc123',
          passphrase: 'groupsecret12345',
          hostAddress: '127.0.0.1',
        ),
        frequencyMhz: 5180,
      ),
      error: null,
    );
  }

  @override
  Future<void> removeGroup() async {
    calls.add('remove');
    hosting = false;
  }

  @override
  Future<String?> connect({
    required String networkName,
    required String passphrase,
  }) async {
    calls.add('connect:$networkName:$passphrase');
    return connectResult;
  }

  @override
  Future<void> disconnect() async => calls.add('disconnect');
}

class _FakeHotspot implements LocalHotspotService {
  final List<String> calls = [];

  @override
  bool get isHosting => false;

  @override
  Future<HotspotStartResult> start() async {
    calls.add('start');
    return const HotspotStartResult.failure(HotspotStartError.unsupported);
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<bool> join({required String ssid, required String passphrase}) async {
    calls.add('join:$ssid');
    return true;
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

PairingCoordinator _pairing(
  AppContainer c, {
  required _FakeWifiDirect wifiDirect,
  required _FakeHotspot hotspot,
  List<String> addresses = const ['127.0.0.1'],
  StreamController<Object?>? sessions,
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
    wifiDirect: wifiDirect,
    localAddresses: () async => addresses,
    activeSessionCount: () => 0,
    sessionChanges: sessions?.stream,
    hotspotIdleTimeout: const Duration(milliseconds: 50),
  );
}

void main() {
  group('pairing payload', () {
    test('Wi-Fi Direct details survive the link and NFC encodings', () {
      final payload = PairingPayload(
        deviceIdHex: 'ab' * 16,
        displayName: 'Phone',
        lanAddress: '192.168.49.1',
        lanPort: 53531,
        pairingToken: 'cd' * 16,
        wifiSsid: 'DIRECT-vy-abc123',
        wifiPassphrase: 'groupsecret12345',
        wifiDirect: true,
        fallbackLanAddress: '192.168.1.20',
      );
      for (final decoded in [
        PairingPayload.fromUri(payload.toUri()),
        PairingPayload.fromJson(payload.toJson()),
      ]) {
        expect(decoded.wifiDirect, isTrue);
        expect(decoded.fallbackLanAddress, '192.168.1.20');
        expect(decoded.wifiSsid, 'DIRECT-vy-abc123');
        expect(decoded.lanAddress, '192.168.49.1');
      }
    });

    test('codes from older builds read as no Wi-Fi Direct', () {
      final uri = Uri.parse(
        'vayu://pair?id=${'ab' * 16}&token=${'cd' * 16}&lan=10.0.0.2:53531'
        '&ssid=AndroidShare_1&psk=secret12',
      );
      final decoded = PairingPayload.fromUri(uri);
      expect(decoded.wifiDirect, isFalse);
      expect(decoded.fallbackLanAddress, isNull);
    });
  });

  group('coordinator', () {
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

    test(
      'the Receive code carries the group, with the router as fallback',
      () async {
        final wifiDirect = _FakeWifiDirect();
        final hotspot = _FakeHotspot();
        final pairing = _pairing(
          host,
          wifiDirect: wifiDirect,
          hotspot: hotspot,
          addresses: ['192.168.1.20'],
        );
        final (payload, error) = await pairing.prepareShowableCode();
        expect(error, isNull);
        expect(payload!.wifiDirect, isTrue);
        expect(payload.wifiSsid, 'DIRECT-vy-abc123');
        expect(payload.lanAddress, '127.0.0.1');
        expect(payload.fallbackLanAddress, '192.168.1.20');
        expect(hotspot.calls, isEmpty);
      },
    );

    test('without a group the code is exactly as before', () async {
      final wifiDirect = _FakeWifiDirect()
        ..createError = HotspotStartError.failed;
      final pairing = _pairing(
        host,
        wifiDirect: wifiDirect,
        hotspot: _FakeHotspot(),
        addresses: ['192.168.1.20'],
      );
      final (payload, error) = await pairing.prepareShowableCode();
      expect(error, isNull);
      expect(payload!.wifiDirect, isFalse);
      expect(payload.wifiSsid, isNull);
      expect(payload.lanAddress, '192.168.1.20');
    });

    test('phones without Wi-Fi Direct never try to create a group', () async {
      final wifiDirect = _FakeWifiDirect()..supported = false;
      final pairing = _pairing(
        host,
        wifiDirect: wifiDirect,
        hotspot: _FakeHotspot(),
      );
      final (payload, _) = await pairing.prepareShowableCode();
      expect(payload!.wifiDirect, isFalse);
      expect(wifiDirect.calls, isEmpty);
    });

    test('the sender joins the group and leaves it when idle', () async {
      final sessions = StreamController<Object?>.broadcast();
      final hostDirect = _FakeWifiDirect();
      final hostPairing = _pairing(
        host,
        wifiDirect: hostDirect,
        hotspot: _FakeHotspot(),
        sessions: sessions,
      );
      final joinDirect = _FakeWifiDirect();
      final joinHotspot = _FakeHotspot();
      final joinPairing = _pairing(
        joiner,
        wifiDirect: joinDirect,
        hotspot: joinHotspot,
        sessions: sessions,
      );

      final (payload, _) = await hostPairing.prepareShowableCode();
      final peer = await joinPairing.join(payload!);
      expect(peer.displayName, 'Host');
      expect(
        joinDirect.calls.first,
        'connect:DIRECT-vy-abc123:groupsecret12345',
      );
      expect(joinHotspot.calls, isEmpty);

      hostPairing.releaseHotspotWhenIdle();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(hostDirect.calls, contains('remove'));
      expect(joinDirect.calls, contains('disconnect'));
      await sessions.close();
    });

    test('a failed group join falls back to the shared router', () async {
      final hostPairing = _pairing(
        host,
        wifiDirect: _FakeWifiDirect(),
        hotspot: _FakeHotspot(),
      );
      final joinDirect = _FakeWifiDirect()..connectResult = null;
      final joinHotspot = _FakeHotspot();
      final joinPairing = _pairing(
        joiner,
        wifiDirect: joinDirect,
        hotspot: joinHotspot,
      );

      final (payload, _) = await hostPairing.prepareShowableCode();
      // Joining the group fails, so the router address is used; the
      // group is never joined the hotspot way while that works.
      final peer = await joinPairing.join(payload!);
      expect(peer.displayName, 'Host');
      expect(joinHotspot.calls, isEmpty);
    });

    test(
      'without Wi-Fi Direct or a router the group is joined like a hotspot',
      () async {
        final hostPairing = _pairing(
          host,
          wifiDirect: _FakeWifiDirect(),
          hotspot: _FakeHotspot(),
          addresses: const [],
        );
        final joinDirect = _FakeWifiDirect()..supported = false;
        final joinHotspot = _FakeHotspot();
        final joinPairing = _pairing(
          joiner,
          wifiDirect: joinDirect,
          hotspot: joinHotspot,
        );

        final (payload, _) = await hostPairing.prepareShowableCode();
        expect(payload!.fallbackLanAddress, isNull);
        final peer = await joinPairing.join(payload);
        expect(peer.displayName, 'Host');
        expect(joinHotspot.calls.first, 'join:DIRECT-vy-abc123');
        expect(joinDirect.calls, isEmpty);
      },
    );
  });
}
