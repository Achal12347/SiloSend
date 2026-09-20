import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/discovery/ble_discovery_service.dart';
import 'package:silosend_datasharing_app/domain/discovery/discovery_beacon.dart';

void main() {
  group('BleDiscoveryService Tests', () {
    const localId = '11111111222233334444555566667777';

    late BleDiscoveryService service;

    setUp(() {
      service = BleDiscoveryService(localDeviceId: localId);
    });

    tearDown(() {
      service.dispose();
    });

    test('initializes with transportType ble', () {
      expect(service.transportType, equals(TransportType.ble));
      expect(service.isScanning, isFalse);
      expect(service.isAdvertising, isFalse);
    });

    test('parses raw scan results and emits DiscoveredPeer with isIdentityVerified false', () async {
      final remoteBytes = Uint8List.fromList(
        List<int>.generate(16, (i) => 0x99),
      );

      final beacon = DiscoveryBeacon(
        deviceId: remoteBytes,
        port: 53531,
        supportedTransports: {TransportType.ble},
        displayName: 'Nearby-Pixel',
      );

      final rawBytes = beacon.toBytes();

      final emittedPeers = <DiscoveredPeer>[];
      final sub = service.discoveredPeers.listen(emittedPeers.add);

      service.handleRawScanResult(
        rawBeaconBytes: rawBytes,
        rssi: -65,
        deviceAddress: 'AA:BB:CC:DD:EE:FF',
      );

      await pumpEventQueue();

      expect(emittedPeers.length, equals(1));
      final peer = emittedPeers.first;
      expect(peer.deviceId, equals(beacon.deviceIdHex));
      expect(peer.displayName, equals('Nearby-Pixel'));
      expect(peer.transportType, equals(TransportType.ble));
      expect(peer.rssi, equals(-65));
      expect(peer.endpointAddress, equals('AA:BB:CC:DD:EE:FF'));
      expect(peer.isIdentityVerified, isFalse); // Strictly unverified

      await sub.cancel();
    });

    test('filters out self-advertisement beacons', () async {
      // Local device beacon
      final localBytes = Uint8List(16);
      for (int i = 0; i < 16; i++) {
        localBytes[i] = int.parse(
          localId.substring(i * 2, i * 2 + 2),
          radix: 16,
        );
      }

      final selfBeacon = DiscoveryBeacon(
        deviceId: localBytes,
        port: 53531,
        supportedTransports: {TransportType.ble},
        displayName: 'Myself',
      );

      final emittedPeers = <DiscoveredPeer>[];
      final sub = service.discoveredPeers.listen(emittedPeers.add);

      service.handleRawScanResult(
        rawBeaconBytes: selfBeacon.toBytes(),
        rssi: -30,
        deviceAddress: '00:11:22:33:44:55',
      );

      await pumpEventQueue();
      expect(emittedPeers, isEmpty);

      await sub.cancel();
    });

    test('ignores malformed byte buffers without crashing', () async {
      final emittedPeers = <DiscoveredPeer>[];
      final sub = service.discoveredPeers.listen(emittedPeers.add);

      // Corrupt buffer
      service.handleRawScanResult(
        rawBeaconBytes: Uint8List.fromList([0x01, 0x02, 0x03]),
        rssi: -80,
      );

      await pumpEventQueue();
      expect(emittedPeers, isEmpty);

      await sub.cancel();
    });
  });
}
