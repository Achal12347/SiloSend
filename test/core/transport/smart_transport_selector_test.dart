import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/link_upgrade_service.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/wifi_direct_service.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transport/smart_transport_selector_impl.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/platform/platform_service.dart';

class _MockPlatformService extends PlatformService {
  final DeviceCapabilities capabilities = const DeviceCapabilities.fromBooleans(
    supportsBle: true,
    supportsBleAdvertising: true,
    supportsWifiDirect: true,
    supportsNfc: true,
    hasCamera: true,
  );

  _MockPlatformService();

  @override
  String get platformName => 'android';
  @override
  Future<DeviceCapabilities> getCapabilities() async => capabilities;
  @override
  Future<bool> isBleSupported() async => capabilities.supportsBle;
  @override
  Future<bool> isWifiDirectSupported() async => capabilities.supportsWifiDirect;
  @override
  Future<bool> requestPermissions() async => true;
}

class _MockBatteryProvider implements BatteryStateProvider {
  BatterySnapshot snapshot;
  _MockBatteryProvider({required this.snapshot});

  @override
  Future<int?> getBatteryLevel() async => snapshot.batteryLevel;
  @override
  Future<bool?> isCharging() async => snapshot.isCharging;
  @override
  Future<bool?> isBatterySaverActive() async => snapshot.isBatterySaverActive;
  @override
  Future<BatterySnapshot> getBatterySnapshot() async => snapshot;
}

void main() {
  group('SmartTransportSelector Multi-Criteria & Policy Tests', () {
    late LocalDeviceIdentity localIdentity;
    late ConnectionManager connectionManager;
    late SecureSessionManager secureSessionManager;
    late _MockPlatformService platformService;
    late _MockBatteryProvider batteryProvider;
    late SmartTransportSelectorImpl selector;

    setUp(() {
      localIdentity = LocalDeviceIdentity.generate(
        displayName: 'Test Local',
        platform: 'android',
      );
      connectionManager = ConnectionManager(
        localIdentity: localIdentity,
        supportedTransports: {TransportType.lan, TransportType.ble},
      );
      secureSessionManager = SecureSessionManager(
        cryptoService: CryptoService(),
        trustStore: PeerTrustStore(),
        secureKeyStore: InMemorySecureKeyStore(),
        localIdentity: localIdentity,
      );
      platformService = _MockPlatformService();
      batteryProvider = _MockBatteryProvider(
        snapshot: BatterySnapshot(
          batteryLevel: 90,
          isCharging: true,
          isBatterySaverActive: false,
          timestamp: DateTime.now(),
        ),
      );
      selector = SmartTransportSelectorImpl(
        platformService: platformService,
        batteryProvider: batteryProvider,
        connectionManager: connectionManager,
        secureSessionManager: secureSessionManager,
      );
    });

    tearDown(() {
      connectionManager.dispose();
      secureSessionManager.dispose();
    });

    test(
      'Small payload (<= 32 KiB) selects BLE when only BLE is available',
      () async {
        final blePeer = DiscoveredPeer(
          deviceId: '00112233445566778899aabbccddeeff',
          displayName: 'BLE Remote',
          transportType: TransportType.ble,
          availableTransports: {TransportType.ble},
          rssi: -55,
          endpointAddress: 'AA:BB:CC:DD:EE:FF',
          lastSeen: DateTime.now(),
        );

        final result = await selector.selectTransport(
          TransportSelectionRequest(
            targetPeer: blePeer,
            payloadSizeBytes: 5000, // 5 KB contact or chat message
          ),
        );

        expect(result.selectedTransport, TransportType.ble);
        expect(result.fallbackChain, isEmpty);
        expect(result.rankedCandidates.first.isAvailable, isTrue);
        expect(result.rankedCandidates.first.score, greaterThanOrEqualTo(60.0));
      },
    );

    test(
      'Large payload (> 128 KiB) with BLE and LAN available prefers LAN',
      () async {
        final dualPeer = DiscoveredPeer(
          deviceId: '112233445566778899aabbccddeeff00',
          displayName: 'Dual Remote',
          transportType: TransportType.lan,
          availableTransports: {TransportType.lan, TransportType.ble},
          rssi: -65,
          endpointAddress: '192.168.1.105:53531',
          lastSeen: DateTime.now(),
        );

        final result = await selector.selectTransport(
          TransportSelectionRequest(
            targetPeer: dualPeer,
            payloadSizeBytes: 10 * 1024 * 1024, // 10 MB file
          ),
        );

        expect(result.selectedTransport, TransportType.lan);
        // For 10 MB, BLE is disqualified because it exceeds 256 KiB maximum recommended size
        expect(result.fallbackChain, isEmpty);
        expect(result.rankedCandidates.first.transport, TransportType.lan);
      },
    );

    test('Payload exceeding BLE max recommended size (> 256 KiB) is disqualified on BLE', () async {
      final bleOnlyPeer = DiscoveredPeer(
        deviceId: '2233445566778899aabbccddeeff0011',
        displayName: 'BLE Only Peer',
        transportType: TransportType.ble,
        availableTransports: {TransportType.ble},
        rssi: -50,
        endpointAddress: '11:22:33:44:55:66',
        lastSeen: DateTime.now(),
      );

      // 500 KB file transfer requested over BLE-only peer
      expect(
        () => selector.selectTransport(
          TransportSelectionRequest(
            targetPeer: bleOnlyPeer,
            payloadSizeBytes: 500 * 1024,
          ),
        ),
        throwsA(
          isA<NoViableTransportException>().having(
            (e) => e.candidateScores
                .firstWhere((c) => c.transport == TransportType.ble)
                .disqualifyReason,
            'disqualifyReason',
            'payload_exceeds_ble_max_recommended',
          ),
        ),
      );
    });

    test('Minimum Viability Invariant: Low battery does NOT pick BLE for a 4 GB transfer', () async {
      // Set battery to 8% critical discharging
      batteryProvider.snapshot = BatterySnapshot(
        batteryLevel: 8,
        isCharging: false,
        isBatterySaverActive: true,
        timestamp: DateTime.now(),
      );

      final dualPeer = DiscoveredPeer(
        deviceId: '33445566778899aabbccddeeff001122',
        displayName: 'Dual Peer Low Battery',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan, TransportType.ble},
        rssi: -50,
        endpointAddress: '192.168.1.120:53531',
        lastSeen: DateTime.now(),
      );

      // 4 GB transfer
      final result = await selector.selectTransport(
        TransportSelectionRequest(
          targetPeer: dualPeer,
          payloadSizeBytes: 4 * 1024 * 1024 * 1024,
        ),
      );

      // LAN MUST still win because BLE was disqualified for 4 GB transfer
      expect(result.selectedTransport, TransportType.lan);
    });

    test('LAN requires valid endpoint: missing port or malformed IP disqualifies LAN', () async {
      final invalidLanPeer = DiscoveredPeer(
        deviceId: '445566778899aabbccddeeff00112233',
        displayName: 'Bad Endpoint Peer',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan, TransportType.ble},
        rssi: -60,
        endpointAddress: 'invalid-address-without-port',
        lastSeen: DateTime.now(),
      );

      final result = await selector.selectTransport(
        TransportSelectionRequest(
          targetPeer: invalidLanPeer,
          payloadSizeBytes: 2048,
        ),
      );

      // LAN disqualified due to missing port -> falls back to BLE
      expect(result.selectedTransport, TransportType.ble);
      final lanCandidate = result.rankedCandidates.firstWhere(
        (c) => c.transport == TransportType.lan,
      );
      expect(lanCandidate.isAvailable, isFalse);
      expect(lanCandidate.disqualifyReason, 'missing_valid_lan_endpoint');
    });

    test('Unknown battery state results in neutral score contribution without fabricating data', () async {
      batteryProvider.snapshot = BatterySnapshot.unknown();

      final dualPeer = DiscoveredPeer(
        deviceId: '5566778899aabbccddeeff0011223344',
        displayName: 'Peer Neutral Battery',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan, TransportType.ble},
        rssi: -60,
        endpointAddress: '192.168.1.50:53531',
        lastSeen: DateTime.now(),
      );

      final result = await selector.selectTransport(
        TransportSelectionRequest(
          targetPeer: dualPeer,
          payloadSizeBytes: 10 * 1024, // 10 KB
        ),
      );

      for (final candidate in result.rankedCandidates) {
        if (candidate.isAvailable) {
          // Neutral score is exactly 10.0 (50% of 20.0 max battery weight)
          expect(candidate.factors['batteryConservation'], 10.0);
        }
      }
    });

    test(
      'Wi-Fi Direct is disqualified on a phone that cannot hand it over',
      () async {
        final peer = DiscoveredPeer(
          deviceId: '66778899aabbccddeeff001122334455',
          displayName: 'All Transports Peer',
          transportType: TransportType.lan,
          availableTransports: {
            TransportType.lan,
            TransportType.ble,
            TransportType.wifiDirect,
          },
          rssi: -50,
          endpointAddress: '192.168.1.60:53531',
          lastSeen: DateTime.now(),
        );

        final result = await selector.selectTransport(
          TransportSelectionRequest(targetPeer: peer),
        );

        // This selector has no link upgrade service: Wi-Fi Direct is
        // evaluated but never offered.
        final wifiCandidate = result.rankedCandidates.firstWhere(
          (c) => c.transport == TransportType.wifiDirect,
        );
        expect(wifiCandidate.isAvailable, isFalse);
        expect(wifiCandidate.disqualifyReason, 'local_hardware_unsupported');
        expect(wifiCandidate.score, 0.0);
      },
    );

    test('Fallback chain contains remaining available candidates ordered by score descending', () async {
      final dualPeer = DiscoveredPeer(
        deviceId: '778899aabbccddeeff00112233445566',
        displayName: 'Ordered Fallback Peer',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan, TransportType.ble},
        rssi: -55,
        endpointAddress: '192.168.1.70:53531',
        lastSeen: DateTime.now(),
      );

      // 50 KB payload (both LAN and BLE are qualified)
      final result = await selector.selectTransport(
        TransportSelectionRequest(
          targetPeer: dualPeer,
          payloadSizeBytes: 50 * 1024,
        ),
      );

      expect(result.selectedTransport, TransportType.lan);
      expect(result.fallbackChain, [TransportType.ble]);
      expect(
        result.rankedCandidates[0].score,
        greaterThanOrEqualTo(result.rankedCandidates[1].score),
      );
    });

    test('a usable LAN endpoint is preferred over Wi-Fi Direct for a 2 MB transfer', () async {
      final peer = DiscoveredPeer(
        deviceId: '8899aabbccddeeff0011223344556677',
        displayName: 'LAN and P2P Peer',
        transportType: TransportType.lan,
        availableTransports: {
          TransportType.lan,
          TransportType.ble,
          TransportType.wifiDirect,
        },
        transportEndpoints: {
          TransportType.lan: '192.168.1.90:53531',
          TransportType.ble: 'AA:BB:CC:DD:EE:FF',
        },
        rssi: -55,
        lastSeen: DateTime.now(),
      );
      final lanFirst = SmartTransportSelectorImpl(
        platformService: platformService,
        batteryProvider: batteryProvider,
        connectionManager: connectionManager,
        secureSessionManager: secureSessionManager,
        linkUpgrade: LinkUpgradeService(
          localDeviceId: () => localIdentity.idHex,
          wifiDirect: const UnsupportedWifiDirectService(),
          hotspot: const UnsupportedHotspotService(),
          lanPort: () => 53531,
          hostingBlocker: (_) async => null,
        ),
        wifiDirectSupported: () async => true,
      );

      final result = await lanFirst.selectTransport(
        TransportSelectionRequest(
          targetPeer: peer,
          payloadSizeBytes: 2 * 1024 * 1024,
        ),
      );

      expect(result.selectedTransport, TransportType.lan);
      expect(result.fallbackChain, contains(TransportType.wifiDirect));
    });

    test(
      'measured per-peer throughput can select Wi-Fi Direct over slow LAN',
      () async {
        final peer = DiscoveredPeer(
          deviceId: '8899aabbccddeeff0011223344556677',
          displayName: 'Measured peer',
          transportType: TransportType.lan,
          availableTransports: {
            TransportType.lan,
            TransportType.ble,
            TransportType.wifiDirect,
          },
          transportEndpoints: {
            TransportType.lan: '192.168.1.90:53531',
            TransportType.ble: 'AA:BB:CC:DD:EE:FF',
          },
          rssi: -55,
          lastSeen: DateTime.now(),
        );
        final measured = SmartTransportSelectorImpl(
          platformService: platformService,
          batteryProvider: batteryProvider,
          connectionManager: connectionManager,
          secureSessionManager: secureSessionManager,
          linkUpgrade: LinkUpgradeService(
            localDeviceId: () => localIdentity.idHex,
            wifiDirect: const UnsupportedWifiDirectService(),
            hotspot: const UnsupportedHotspotService(),
            lanPort: () => 53531,
            hostingBlocker: (_) async => null,
          ),
          wifiDirectSupported: () async => true,
          observedThroughput: (_, route) => switch (route) {
            TransportType.lan => 1 * 1024 * 1024,
            TransportType.wifiDirect => 20 * 1024 * 1024,
            _ => null,
          },
        );

        final result = await measured.selectTransport(
          TransportSelectionRequest(
            targetPeer: peer,
            payloadSizeBytes: 100 * 1024 * 1024,
          ),
        );

        expect(result.selectedTransport, TransportType.wifiDirect);
        expect(result.fallbackChain, contains(TransportType.lan));
      },
    );
  });
}
