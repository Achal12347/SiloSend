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
  });
}
