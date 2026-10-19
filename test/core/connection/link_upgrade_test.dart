import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/connection/link_upgrade_service.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/wifi_direct_service.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transfer/transfer_engine_impl.dart';
import 'package:vayu/core/transport/smart_transport_selector_impl.dart';
import 'package:vayu/domain/connection/link_upgrade_payloads.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/platform/platform_service.dart';

/// Wi-Fi Direct stand-in: the "group" is the loopback interface.
class _FakeWifiDirect implements WifiDirectService {
  bool fiveGhz;
  HotspotStartError? createError;
  String? joinResult = '127.0.0.1';
  final createdWith5Ghz = <bool>[];
  final joined = <String>[];
  int disconnects = 0;

  _FakeWifiDirect({this.fiveGhz = true});

  @override
  Future<bool> isSupported() async => true;

  @override
  bool get isHosting => createdWith5Ghz.isNotEmpty;

  @override
  Future<bool> supports5Ghz() async => fiveGhz;

  @override
  Future<({WifiDirectGroup? group, HotspotStartError? error})> createGroup({
    bool allow5Ghz = true,
  }) async {
    final error = createError;
    if (error != null) return (group: null, error: error);
    createdWith5Ghz.add(allow5Ghz);
    return (
      group: WifiDirectGroup(
        credentials: const HotspotCredentials(
          ssid: 'DIRECT-vy-test01',
          passphrase: 'groupsecret12345',
          hostAddress: '127.0.0.1',
        ),
        frequencyMhz: allow5Ghz ? 5180 : 2437,
      ),
      error: null,
    );
  }

  @override
  Future<void> removeGroup() async {}

  @override
  Future<String?> connect({
    required String networkName,
    required String passphrase,
  }) async {
    joined.add('$networkName/$passphrase');
    return joinResult;
  }

  @override
  Future<void> disconnect() async => disconnects++;
}

/// Two phones over loopback with authenticated sessions; B hosts.
class _Pair {
  final a = LocalDeviceIdentity.generate(displayName: 'A', platform: 'android');
  final b = LocalDeviceIdentity.generate(displayName: 'B', platform: 'android');
  final server = LanConnectionServer(requestedPort: 0);
  final wifiA = _FakeWifiDirect(fiveGhz: false);
  final wifiB = _FakeWifiDirect();
  LinkUpgradeDeclineReason? blocker;
  late final ConnectionManager managerA;
  late final ConnectionManager managerB;
  late final SecureSessionManager secureA;
  late final SecureSessionManager secureB;
  late final TransferEngineImpl engineA;
  late final TransferEngineImpl engineB;
  late final LinkUpgradeService upgradeA;
  late final LinkUpgradeService upgradeB;

  Future<void> start({bool answer = true}) async {
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
    engineA = TransferEngineImpl(
      localDeviceId: a.idHex,
      secureSessionManager: secureA,
    );
    engineB = TransferEngineImpl(
      localDeviceId: b.idHex,
      secureSessionManager: secureB,
    );
    upgradeA = LinkUpgradeService(
      localDeviceId: () => a.idHex,
      wifiDirect: wifiA,
      hotspot: const UnsupportedHotspotService(),
      lanPort: () => null,
      hostingBlocker: (_) async => LinkUpgradeDeclineReason.notReceiving,
      sessionChanges: managerA.activeSessionsStream,
      answerTimeout: const Duration(seconds: 2),
    )..attach(engineA.linkUpgradePackets);
    upgradeB = LinkUpgradeService(
      localDeviceId: () => b.idHex,
      wifiDirect: wifiB,
      hotspot: const UnsupportedHotspotService(),
      lanPort: () => server.boundPort,
      hostingBlocker: (_) async => blocker,
    );
    if (answer) upgradeB.attach(engineB.linkUpgradePackets);
  }

  /// The session the credentials travel in (Bluetooth on phones).
  Future<SecureSessionImpl> control() async => secureA.secureOutboundConnection(
    await managerA.connectToLanPeer(
      remoteAddress: '127.0.0.1',
      remotePort: server.boundPort,
    ),
  );

  Future<void> dispose() async {
    await upgradeA.dispose();
    await upgradeB.dispose();
    await engineA.dispose();
    await engineB.dispose();
    await secureA.dispose();
    await secureB.dispose();
    await managerA.dispose();
    await managerB.dispose();
    await server.stop();
  }
}

class _Platform extends PlatformService {
  @override
  String get platformName => 'android';
  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: false,
        supportsNfc: false,
        hasCamera: false,
      );
  @override
  Future<bool> isBleSupported() async => true;
  @override
  Future<bool> isWifiDirectSupported() async => true;
  @override
  Future<bool> requestPermissions() async => true;
}

class _Battery implements BatteryStateProvider {
  final snapshot = BatterySnapshot(
    batteryLevel: 80,
    isCharging: false,
    isBatterySaverActive: false,
    timestamp: DateTime(2026),
  );
  @override
  Future<int?> getBatteryLevel() async => 80;
  @override
  Future<bool?> isCharging() async => false;
  @override
  Future<bool?> isBatterySaverActive() async => false;
  @override
  Future<BatterySnapshot> getBatterySnapshot() async => snapshot;
}

void main() {
  group('messages', () {
    test('request and answer survive encoding', () {
      const id = '0123456789abcdef0123456789abcdef';
      final request = LinkUpgradeRequest.fromBytes(
        const LinkUpgradeRequest(requestId: id, fiveGhz: false).toBytes(),
      );
      expect(request.requestId, id);
      expect(request.fiveGhz, isFalse);

      final answer = LinkUpgradeResponse.fromBytes(
        const LinkUpgradeResponse.accepted(
          requestId: id,
          networkName: 'DIRECT-vy-x',
          passphrase: 'secret123',
          hostAddress: '192.168.49.1',
          port: 53531,
          frequencyMhz: 2437,
        ).toBytes(),
      );
      expect(answer.isAccepted, isTrue);
      expect(answer.hostAddress, '192.168.49.1');
      expect(answer.frequencyMhz, 2437);

      final declined = LinkUpgradeResponse.fromBytes(
        const LinkUpgradeResponse.declined(
          requestId: id,
          declined: LinkUpgradeDeclineReason.notReceiving,
        ).toBytes(),
      );
      expect(declined.declined, LinkUpgradeDeclineReason.notReceiving);
    });

    test('malformed answers are rejected', () {
      for (final bad in [
        '{"id":"short","ssid":"a","pass":"b","host":"1.2.3.4","port":1}',
        '{"id":"0123456789abcdef0123456789abcdef","ssid":"a","pass":"b","host":"evil.example","port":1}',
        '{"id":"0123456789abcdef0123456789abcdef","ssid":"a","pass":"b","host":"1.2.3.4","port":70000}',
        '{"id":"0123456789abcdef0123456789abcdef","ssid":"","pass":"b","host":"1.2.3.4","port":5}',
        '[]',
      ]) {
        expect(
          () => LinkUpgradeResponse.fromBytes(
            Uint8List.fromList(utf8.encode(bad)),
          ),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('route choice', () {
    SmartTransportSelectorImpl selector({required bool wifiDirect}) {
      final identity = LocalDeviceIdentity.generate(
        displayName: 'Local',
        platform: 'android',
      );
      final connections = ConnectionManager(localIdentity: identity);
      return SmartTransportSelectorImpl(
        platformService: _Platform(),
        batteryProvider: _Battery(),
        connectionManager: connections,
        secureSessionManager: SecureSessionManager(
          cryptoService: CryptoService(),
          trustStore: PeerTrustStore(),
          secureKeyStore: InMemorySecureKeyStore(),
          localIdentity: identity,
        ),
        linkUpgrade: LinkUpgradeService(
          localDeviceId: () => identity.idHex,
          wifiDirect: const UnsupportedWifiDirectService(),
          hotspot: const UnsupportedHotspotService(),
          lanPort: () => null,
          hostingBlocker: (_) async => null,
        ),
        wifiDirectSupported: () async => wifiDirect,
      );
    }

    DiscoveredPeer peer({bool lan = true, bool ble = true}) => DiscoveredPeer(
      deviceId: '00112233445566778899aabbccddeeff',
      displayName: 'Peer',
      transportType: ble ? TransportType.ble : TransportType.lan,
      availableTransports: {
        if (lan) TransportType.lan,
        if (ble) TransportType.ble,
        TransportType.wifiDirect,
      },
      rssi: -55,
      endpointAddress: lan ? '192.168.1.20:53531' : 'AA:BB:CC:DD:EE:FF',
      transportEndpoints: {
        if (lan) TransportType.lan: '192.168.1.20:53531',
        if (ble) TransportType.ble: 'AA:BB:CC:DD:EE:FF',
      },
      lastSeen: DateTime.now(),
    );

    Future<TransportSelectionResult> choose(
      DiscoveredPeer p, {
      int bytes = 200 * 1000 * 1000,
      bool wifiDirect = true,
    }) => selector(wifiDirect: wifiDirect).selectTransport(
      TransportSelectionRequest(targetPeer: p, payloadSizeBytes: bytes),
    );

    test('on the same Wi-Fi too: Wi-Fi Direct from Bluetooth first, '
        'the router as the fallback', () async {
      final result = await choose(peer());
      expect(result.selectedTransport, TransportType.wifiDirect);
      expect(result.fallbackChain.first, TransportType.lan);
    });

    test('small items on the same Wi-Fi do not make a group', () async {
      final result = await choose(peer(), bytes: 2000);
      expect(result.selectedTransport, isNot(TransportType.wifiDirect));
    });

    test('found only over Bluetooth: Wi-Fi Direct for files', () async {
      final result = await choose(peer(lan: false));
      expect(result.selectedTransport, TransportType.wifiDirect);
    });

    test('small items stay on Bluetooth', () async {
      final result = await choose(peer(lan: false), bytes: 2000);
      expect(result.selectedTransport, TransportType.ble);
      final direct = result.rankedCandidates.firstWhere(
        (c) => c.transport == TransportType.wifiDirect,
      );
      expect(direct.disqualifyReason, 'payload_small_use_ble');
    });

    test('without Bluetooth there is nothing to hand the group over', () async {
      final result = await choose(peer(ble: false));
      final direct = result.rankedCandidates.firstWhere(
        (c) => c.transport == TransportType.wifiDirect,
      );
      expect(direct.disqualifyReason, 'no_bluetooth_to_hand_over');
    });

    test('a phone without Wi-Fi Direct never offers it, and says so', () async {
      // 200 MB to a phone only reachable over Bluetooth: no route at all.
      await expectLater(
        choose(peer(lan: false), wifiDirect: false),
        throwsA(
          isA<NoViableTransportException>().having(
            (e) => e.candidateScores
                .firstWhere((c) => c.transport == TransportType.wifiDirect)
                .disqualifyReason,
            'Wi-Fi Direct reason',
            'local_hardware_unsupported',
          ),
        ),
      );
    });
  });

  group('hand-over inside the encrypted session', () {
    test('both builds advertise the feature', () async {
      final pair = _Pair();
      await pair.start();
      try {
        final control = await pair.control();
        expect(
          control.connectionSession.info.remoteFeatures,
          contains(AppConstants.featureLinkUpgrade),
        );
      } finally {
        await pair.dispose();
      }
    });

    test('the host makes a 2.4 GHz group for a phone without 5 GHz, '
        'and the Wi-Fi link authenticates', () async {
      final pair = _Pair();
      await pair.start();
      try {
        final control = await pair.control();
        final link = await pair.upgradeA.upgrade(control);

        expect(pair.wifiB.createdWith5Ghz, [false]);
        expect(link.frequencyMhz, 2437);
        expect(link.port, pair.server.boundPort);
        expect(pair.wifiA.joined, ['DIRECT-vy-test01/groupsecret12345']);

        // The new link goes through the full handshake, bound to B.
        final wifi = await pair.secureA.secureOutboundConnection(
          await pair.managerA.connectToLanPeer(
            remoteAddress: link.host,
            remotePort: link.port,
          ),
        );
        expect(wifi.isEstablished, isTrue);
        expect(wifi.remoteDeviceId, control.remoteDeviceId);
        expect(wifi.sessionId, isNot(control.sessionId));

        // Closing the Wi-Fi link leaves the group.
        pair.upgradeA.leaveWhenClosed(wifi.connectionSession, link);
        await wifi.connectionSession.close(reason: 'done');
        for (var i = 0; i < 50 && pair.wifiA.disconnects == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(pair.wifiA.disconnects, 1);
      } finally {
        await pair.dispose();
      }
    });

    test(
      'off the Receive screen the host declines and nothing is joined',
      () async {
        final pair = _Pair()..blocker = LinkUpgradeDeclineReason.notReceiving;
        await pair.start();
        try {
          final control = await pair.control();
          await expectLater(
            pair.upgradeA.upgrade(control),
            throwsA(
              isA<LinkUpgradeException>().having(
                (e) => e.declined,
                'declined',
                LinkUpgradeDeclineReason.notReceiving,
              ),
            ),
          );
          expect(pair.wifiB.createdWith5Ghz, isEmpty);
          expect(pair.wifiA.joined, isEmpty);
        } finally {
          await pair.dispose();
        }
      },
    );

    test(
      'a refused permission on the host is reported as not allowed',
      () async {
        final pair = _Pair();
        pair.wifiB.createError = HotspotStartError.permissionDenied;
        await pair.start();
        try {
          final control = await pair.control();
          await expectLater(
            pair.upgradeA.upgrade(control),
            throwsA(
              isA<LinkUpgradeException>().having(
                (e) => e.declined,
                'declined',
                LinkUpgradeDeclineReason.notAllowed,
              ),
            ),
          );
        } finally {
          await pair.dispose();
        }
      },
    );

    test('a failed join is an error, not a silent fallback', () async {
      final pair = _Pair();
      pair.wifiA.joinResult = null;
      await pair.start();
      try {
        final control = await pair.control();
        await expectLater(
          pair.upgradeA.upgrade(control),
          throwsA(
            isA<LinkUpgradeException>().having(
              (e) => e.declined,
              'declined',
              isNull,
            ),
          ),
        );
      } finally {
        await pair.dispose();
      }
    });

    test('no answer ends with an error after the timeout', () async {
      final pair = _Pair();
      await pair.start(answer: false);
      try {
        final control = await pair.control();
        await expectLater(
          pair.upgradeA.upgrade(control),
          throwsA(isA<LinkUpgradeException>()),
        );
      } finally {
        await pair.dispose();
      }
    });
  });
}
