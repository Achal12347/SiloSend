import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/discovery/discovery_coordinator.dart';

class MockDiscoveryService implements DiscoveryService {
  @override
  final TransportType transportType;
  final _controller = StreamController<DiscoveredPeer>.broadcast();

  bool isScanning = false;
  bool isAdvertising = false;

  MockDiscoveryService(this.transportType);

  @override
  Stream<DiscoveredPeer> get discoveredPeers => _controller.stream;

  @override
  Future<void> startDiscovery() async => isScanning = true;

  @override
  Future<void> stopDiscovery() async => isScanning = false;

  @override
  Future<void> startAdvertising(DeviceAdvertisement advertisement) async =>
      isAdvertising = true;

  @override
  Future<void> stopAdvertising() async => isAdvertising = false;

  void emitPeer(DiscoveredPeer peer) => _controller.add(peer);

  void dispose() => _controller.close();
}

void main() {
  group('DiscoveryCoordinator Tests', () {
    late MockDiscoveryService lanService;
    late MockDiscoveryService bleService;
    late DiscoveryCoordinator coordinator;

    setUp(() {
      lanService = MockDiscoveryService(TransportType.lan);
      bleService = MockDiscoveryService(TransportType.ble);
      coordinator = DiscoveryCoordinator(
        services: [lanService, bleService],
        staleTimeout: const Duration(milliseconds: 100),
        reaperInterval: const Duration(milliseconds: 50),
      );
    });

    tearDown(() {
      coordinator.dispose();
      lanService.dispose();
      bleService.dispose();
    });

    test('aggregates discovered peers from multiple services', () async {
      await coordinator.startDiscovery();
      expect(coordinator.status, equals(DiscoveryStatus.active));

      lanService.emitPeer(
        DiscoveredPeer(
          deviceId: '11111111111111111111111111111111',
          displayName: 'LAN-Peer',
          transportType: TransportType.lan,
          rssi: 0,
          lastSeen: DateTime.now(),
        ),
      );

      bleService.emitPeer(
        DiscoveredPeer(
          deviceId: '22222222222222222222222222222222',
          displayName: 'BLE-Peer',
          transportType: TransportType.ble,
          rssi: -70,
          lastSeen: DateTime.now(),
        ),
      );

      await pumpEventQueue();

      expect(coordinator.currentPeers.length, equals(2));
      expect(
        coordinator.currentPeers.any((p) => p.displayName == 'LAN-Peer'),
        isTrue,
      );
      expect(
        coordinator.currentPeers.any((p) => p.displayName == 'BLE-Peer'),
        isTrue,
      );
    });

    test('deduplicates and merges transports for identical peer ID', () async {
      await coordinator.startDiscovery();

      const peerId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

      // 1. Observed via LAN
      lanService.emitPeer(
        DiscoveredPeer(
          deviceId: peerId,
          displayName: 'Dual-Device',
          transportType: TransportType.lan,
          rssi: 0,
          lastSeen: DateTime.now(),
        ),
      );

      await pumpEventQueue();
      expect(coordinator.currentPeers.length, equals(1));
      expect(
        coordinator.currentPeers.first.availableTransports,
        equals({TransportType.lan}),
      );

      // 2. Observed via BLE
      bleService.emitPeer(
        DiscoveredPeer(
          deviceId: peerId,
          displayName: 'Dual-Device',
          transportType: TransportType.ble,
          rssi: -50,
          lastSeen: DateTime.now(),
        ),
      );

      await pumpEventQueue();

      // Still exactly 1 peer (deduplicated by deviceId!)
      expect(coordinator.currentPeers.length, equals(1));
      final mergedPeer = coordinator.currentPeers.first;
      expect(mergedPeer.deviceId, equals(peerId));
      expect(
        mergedPeer.availableTransports,
        containsAll([TransportType.lan, TransportType.ble]),
      );
      expect(mergedPeer.rssi, equals(-50));
      expect(mergedPeer.isIdentityVerified, isFalse);
    });

    test('evicts stale peers after timeout', () async {
      await coordinator.startDiscovery();

      lanService.emitPeer(
        DiscoveredPeer(
          deviceId: '33333333333333333333333333333333',
          displayName: 'Short-Lived-Peer',
          transportType: TransportType.lan,
          rssi: 0,
          lastSeen: DateTime.now().subtract(const Duration(milliseconds: 200)),
        ),
      );

      await pumpEventQueue();
      expect(coordinator.currentPeers.length, equals(1));

      // Trigger eviction
      coordinator.evictStalePeersForTesting();

      expect(coordinator.currentPeers, isEmpty);
    });

    test(
      'deduplicates and merges transports when BLE discovered before LAN',
      () async {
        await coordinator.startDiscovery();

        const peerId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

        // 1. Observed via BLE first
        bleService.emitPeer(
          DiscoveredPeer(
            deviceId: peerId,
            displayName: 'BLE-First-Device',
            transportType: TransportType.ble,
            rssi: -45,
            lastSeen: DateTime.now(),
          ),
        );

        await pumpEventQueue();
        expect(coordinator.currentPeers.length, equals(1));
        expect(
          coordinator.currentPeers.first.availableTransports,
          equals({TransportType.ble}),
        );

        // 2. Observed via LAN second
        lanService.emitPeer(
          DiscoveredPeer(
            deviceId: peerId,
            displayName: 'BLE-First-Device',
            transportType: TransportType.lan,
            rssi: 0,
            lastSeen: DateTime.now(),
          ),
        );

        await pumpEventQueue();
        expect(coordinator.currentPeers.length, equals(1));
        final merged = coordinator.currentPeers.first;
        expect(
          merged.availableTransports,
          containsAll([TransportType.ble, TransportType.lan]),
        );
        expect(merged.rssi, equals(-45)); // Retains non-zero BLE RSSI
      },
    );

    test(
      'merges advertised wifiDirect capability into transport set',
      () async {
        await coordinator.startDiscovery();

        const peerId = 'cccccccccccccccccccccccccccccccc';

        lanService.emitPeer(
          DiscoveredPeer(
            deviceId: peerId,
            displayName: 'Multi-Cap-Device',
            transportType: TransportType.lan,
            availableTransports: {TransportType.lan, TransportType.wifiDirect},
            rssi: 0,
            lastSeen: DateTime.now(),
          ),
        );

        await pumpEventQueue();
        expect(coordinator.currentPeers.length, equals(1));
        expect(
          coordinator.currentPeers.first.availableTransports,
          containsAll([TransportType.lan, TransportType.wifiDirect]),
        );

        bleService.emitPeer(
          DiscoveredPeer(
            deviceId: peerId,
            displayName: 'Multi-Cap-Device',
            transportType: TransportType.ble,
            rssi: -60,
            lastSeen: DateTime.now(),
          ),
        );

        await pumpEventQueue();
        expect(
          coordinator.currentPeers.first.availableTransports,
          containsAll([
            TransportType.lan,
            TransportType.wifiDirect,
            TransportType.ble,
          ]),
        );
      },
    );

    test('tracks full operational state transitions (idle -> starting -> active -> stopping -> idle)', () async {
      final observedStatuses = <DiscoveryStatus>[];
      final sub = coordinator.statusStream.listen(observedStatuses.add);

      expect(coordinator.status, equals(DiscoveryStatus.idle));

      await coordinator.startDiscovery();
      expect(coordinator.status, equals(DiscoveryStatus.active));

      await coordinator.stopDiscovery();
      await pumpEventQueue();
      expect(coordinator.status, equals(DiscoveryStatus.idle));

      expect(
        observedStatuses,
        equals([
          DiscoveryStatus.starting,
          DiscoveryStatus.active,
          DiscoveryStatus.stopping,
          DiscoveryStatus.idle,
        ]),
      );

      await sub.cancel();
    });

    test('transitions to error status when a service fails to start', () async {
      final failingService = _FailingDiscoveryService();
      final errCoordinator = DiscoveryCoordinator(services: [failingService]);

      final observedStatuses = <DiscoveryStatus>[];
      final sub = errCoordinator.statusStream.listen(observedStatuses.add);

      expect(() => errCoordinator.startDiscovery(), throwsA(isA<Exception>()));

      await pumpEventQueue();

      expect(errCoordinator.status, equals(DiscoveryStatus.error));
      expect(observedStatuses, contains(DiscoveryStatus.error));

      await sub.cancel();
      errCoordinator.dispose();
      failingService.dispose();
    });

    test(
      'refreshes lastSeen when peer re-advertises, preventing eviction',
      () async {
        await coordinator.startDiscovery();

        const peerId = 'dddddddddddddddddddddddddddddddd';

        // 1. Initial observation
        lanService.emitPeer(
          DiscoveredPeer(
            deviceId: peerId,
            displayName: 'Persistent-Device',
            transportType: TransportType.lan,
            rssi: 0,
            lastSeen: DateTime.now().subtract(const Duration(milliseconds: 80)),
          ),
        );

        await pumpEventQueue();
        expect(coordinator.currentPeers.length, equals(1));

        // 2. Refreshed observation with now()
        lanService.emitPeer(
          DiscoveredPeer(
            deviceId: peerId,
            displayName: 'Persistent-Device',
            transportType: TransportType.lan,
            rssi: 0,
            lastSeen: DateTime.now(),
          ),
        );

        await pumpEventQueue();

        // Trigger eviction check (staleTimeout = 100ms)
        coordinator.evictStalePeersForTesting();

        // Peer should NOT be evicted because lastSeen was refreshed!
        expect(coordinator.currentPeers.length, equals(1));
      },
    );
  });
}

class _FailingDiscoveryService implements DiscoveryService {
  @override
  TransportType get transportType => TransportType.lan;

  final _controller = StreamController<DiscoveredPeer>.broadcast();

  @override
  Stream<DiscoveredPeer> get discoveredPeers => _controller.stream;

  @override
  Future<void> startDiscovery() async {
    throw Exception('Simulated socket failure');
  }

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> startAdvertising(DeviceAdvertisement advertisement) async {}

  @override
  Future<void> stopAdvertising() async {}

  void dispose() => _controller.close();
}
