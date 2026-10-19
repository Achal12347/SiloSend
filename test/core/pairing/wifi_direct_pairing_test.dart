import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
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
  Future<bool> supports5Ghz() async => true;

  @override
  Future<({WifiDirectGroup? group, HotspotStartError? error})> createGroup({
    bool allow5Ghz = true,
  }) async {
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

/// A real selector whose secure handshake takes [handshake]: a caller that
/// gives the connection less time than that gets a timeout, as on a slow
/// phone right after the app starts.
class _SlowHandshakeSelector implements TransportSelector {
  final TransportSelector inner;
  final Duration handshake;
  final timeoutsGiven = <Duration?>[];

  _SlowHandshakeSelector(this.inner, this.handshake);

  @override
  Future<TransportSelectionResult> selectTransport(
    TransportSelectionRequest request,
  ) => inner.selectTransport(request);

  @override
  Future<SecureSession> connectWithSmartSelection(
    DiscoveredPeer peer, {
    TransportSelectionRequest? request,
    Duration? timeout,
  }) async {
    timeoutsGiven.add(timeout);
    if (timeout != null && timeout < handshake) {
      throw TimeoutException('handshake cut off', timeout);
    }
    return inner.connectWithSmartSelection(
      peer,
      request: request,
      timeout: timeout,
    );
  }
}

PairingCoordinator _pairing(
  AppContainer c, {
  required _FakeWifiDirect wifiDirect,
  required _FakeHotspot hotspot,
  List<String> addresses = const ['127.0.0.1'],
  StreamController<Object?>? sessions,
  TransportSelector? selector,
}) {
  return PairingCoordinator(
    identity: () => c.identity,
    lanPort: () => c.lanServer?.boundPort,
    localPublicKeyHex: () => c.localKeypair?.publicKeyHex,
    supportsBle: () => false,
    discoveryCoordinator: c.discoveryCoordinator,
    secureSessionManager: c.secureSessionManager,
    transportSelector: selector ?? c.transportSelector,
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

    test(
      'on the same router a scanned code still joins the group first',
      () async {
        final hostPairing = _pairing(
          host,
          wifiDirect: _FakeWifiDirect(),
          hotspot: _FakeHotspot(),
        );
        final joinDirect = _FakeWifiDirect();
        final joinHotspot = _FakeHotspot();
        final joinPairing = _pairing(
          joiner,
          wifiDirect: joinDirect,
          hotspot: joinHotspot,
        );

        final (payload, _) = await hostPairing.prepareShowableCode();
        expect(payload!.wifiDirect, isTrue);
        final peer = await joinPairing.join(payload);
        expect(peer.displayName, 'Host');
        // Owner's route rule (2026-10-19): Wi-Fi Direct first, even on a
        // shared router.
        expect(
          joinDirect.calls.first,
          'connect:DIRECT-vy-abc123:groupsecret12345',
        );
        expect(joinHotspot.calls, isEmpty);
      },
    );

    test('a slow first handshake over the router is not cut off', () async {
      // Regression: only reaching the router was meant to be time-limited,
      // but the limit covered the whole handshake, so the first scan after
      // an app start failed and the second worked.
      final hostPairing = _pairing(
        host,
        wifiDirect: _FakeWifiDirect(),
        hotspot: _FakeHotspot(),
      );
      // The group join fails, so the router is used.
      final joinDirect = _FakeWifiDirect()..connectResult = null;
      final slow = _SlowHandshakeSelector(
        joiner.transportSelector,
        PairingCoordinator.sharedWifiProbeTimeout + const Duration(seconds: 1),
      );
      final joinPairing = _pairing(
        joiner,
        wifiDirect: joinDirect,
        hotspot: _FakeHotspot(),
        selector: slow,
      );

      final (payload, _) = await hostPairing.prepareShowableCode();
      final peer = await joinPairing.join(payload!);
      expect(peer.displayName, 'Host');
      expect(slow.timeoutsGiven, [null]);
    });

    test('the sender joins the group and leaves it when idle', () async {
      final sessions = StreamController<Object?>.broadcast();
      final hostDirect = _FakeWifiDirect();
      final hostPairing = _pairing(
        host,
        wifiDirect: hostDirect,
        hotspot: _FakeHotspot(),
        // A router address the joiner cannot reach (TEST-NET-1).
        addresses: ['192.0.2.1'],
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
      expect(payload!.fallbackLanAddress, '192.0.2.1');
      final peer = await joinPairing.join(payload);
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

    test(
      'no router and a failed group join: the group is joined as Wi-Fi',
      () async {
        final hostPairing = _pairing(
          host,
          wifiDirect: _FakeWifiDirect(),
          hotspot: _FakeHotspot(),
          addresses: ['192.0.2.1'],
        );
        final joinDirect = _FakeWifiDirect()..connectResult = null;
        final joinHotspot = _FakeHotspot();
        final joinPairing = _pairing(
          joiner,
          wifiDirect: joinDirect,
          hotspot: joinHotspot,
        );

        final (payload, _) = await hostPairing.prepareShowableCode();
        final peer = await joinPairing.join(payload!);
        expect(peer.displayName, 'Host');
        // Joined as Wi-Fi (it is left again once idle).
        expect(joinHotspot.calls.first, 'join:DIRECT-vy-abc123');
      },
    );

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
