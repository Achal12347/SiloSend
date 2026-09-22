import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/discovery/lan_discovery_service.dart';
import 'package:silosend_datasharing_app/domain/discovery/discovery_beacon.dart';

void main() {
  group('LanDiscoveryService Tests', () {
    const localId = '11111111222233334444555566667777';

    test('initializes with transportType lan and inactive status', () {
      final service = LanDiscoveryService(localDeviceId: localId);
      expect(service.transportType, equals(TransportType.lan));
      expect(service.isScanning, isFalse);
      expect(service.isAdvertising, isFalse);
      service.dispose();
    });

    test('starts and stops discovery safely', () async {
      final service = LanDiscoveryService(localDeviceId: localId);

      await service.startDiscovery();
      expect(service.isScanning, isTrue);

      await service.stopDiscovery();
      expect(service.isScanning, isFalse);

      service.dispose();
    });

    test('emits DiscoveredPeer with isIdentityVerified false on valid remote beacon', () async {
      final service = LanDiscoveryService(localDeviceId: localId);
      await service.startDiscovery();

      final remoteBytes = Uint8List.fromList(
        List<int>.generate(16, (i) => 0x44),
      );
      final beacon = DiscoveryBeacon(
        deviceId: remoteBytes,
        port: 53531,
        supportedTransports: {TransportType.lan},
        displayName: 'Remote-LAN-Device',
      );

      final emitted = <DiscoveredPeer>[];
      final sub = service.discoveredPeers.listen(emitted.add);

      service.handleIncomingPacket(
        beacon.toBytes(),
        InternetAddress('192.168.1.105'),
      );

      await pumpEventQueue();

      expect(emitted.length, equals(1));
      final peer = emitted.first;
      expect(peer.deviceId, equals(beacon.deviceIdHex));
      expect(peer.displayName, equals('Remote-LAN-Device'));
      expect(peer.transportType, equals(TransportType.lan));
      expect(peer.endpointAddress, equals('192.168.1.105:53531'));
      expect(peer.isIdentityVerified, isFalse);

      await sub.cancel();
      service.dispose();
    });

    test('filters out self-broadcast beacons', () async {
      final service = LanDiscoveryService(localDeviceId: localId);
      await service.startDiscovery();

      final selfBytes = Uint8List(16);
      for (int i = 0; i < 16; i++) {
        selfBytes[i] = int.parse(
          localId.substring(i * 2, i * 2 + 2),
          radix: 16,
        );
      }
      final selfBeacon = DiscoveryBeacon(
        deviceId: selfBytes,
        port: 53531,
        supportedTransports: {TransportType.lan},
        displayName: 'My-Self',
      );

      final emitted = <DiscoveredPeer>[];
      final sub = service.discoveredPeers.listen(emitted.add);

      service.handleIncomingPacket(
        selfBeacon.toBytes(),
        InternetAddress('192.168.1.50'),
      );

      await pumpEventQueue();

      expect(emitted, isEmpty);

      await sub.cancel();
      service.dispose();
    });

    test(
      'ignores malformed and garbage packets safely without throwing',
      () async {
        final service = LanDiscoveryService(localDeviceId: localId);
        await service.startDiscovery();

        final emitted = <DiscoveredPeer>[];
        final sub = service.discoveredPeers.listen(emitted.add);

        // Garbage random bytes
        service.handleIncomingPacket(
          Uint8List.fromList([0x00, 0x11, 0x22, 0x33, 0x44]),
          InternetAddress('192.168.1.200'),
        );

        // Truncated packet
        service.handleIncomingPacket(
          Uint8List.fromList([0x53, 0x53, 0x01]),
          InternetAddress('192.168.1.200'),
        );

        await pumpEventQueue();

        expect(emitted, isEmpty);

        await sub.cancel();
        service.dispose();
      },
    );

    test('starts and stops advertising lifecycle safely', () async {
      final service = LanDiscoveryService(localDeviceId: localId);

      const ad = DeviceAdvertisement(
        deviceId: localId,
        displayName: 'Local-Host',
        port: 53531,
        supportedTransports: {TransportType.lan},
        protocolVersion: 1,
      );

      await service.startAdvertising(ad);
      expect(service.isAdvertising, isTrue);

      await service.stopAdvertising();
      expect(service.isAdvertising, isFalse);

      service.dispose();
    });
  });
}
