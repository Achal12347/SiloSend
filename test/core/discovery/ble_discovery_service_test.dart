import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/ble_discovery_service.dart';
import 'package:vayu/domain/discovery/discovery_beacon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

    test('ignores truncated BLE beacon without crashing', () async {
      final remoteBytes = Uint8List.fromList(
        List<int>.generate(16, (i) => 0x77),
      );
      final beacon = DiscoveryBeacon(
        deviceId: remoteBytes,
        port: 53531,
        supportedTransports: {TransportType.ble},
        displayName: 'Truncated-Ble',
      );
      final validBytes = beacon.toBytes();
      final truncated = Uint8List.fromList(
        validBytes.sublist(0, validBytes.length - 6),
      );

      final emittedPeers = <DiscoveredPeer>[];
      final sub = service.discoveredPeers.listen(emittedPeers.add);

      service.handleRawScanResult(rawBeaconBytes: truncated, rssi: -80);

      await pumpEventQueue();
      expect(emittedPeers, isEmpty);

      await sub.cancel();
    });

    test('ignores BLE beacon with CRC mismatch', () async {
      final remoteBytes = Uint8List.fromList(
        List<int>.generate(16, (i) => 0x77),
      );
      final beacon = DiscoveryBeacon(
        deviceId: remoteBytes,
        port: 53531,
        supportedTransports: {TransportType.ble},
        displayName: 'Corrupt-Ble',
      );
      final corruptBytes = Uint8List.fromList(beacon.toBytes());
      corruptBytes[5] ^= 0xAA; // Flip bit in device ID

      final emittedPeers = <DiscoveredPeer>[];
      final sub = service.discoveredPeers.listen(emittedPeers.add);

      service.handleRawScanResult(rawBeaconBytes: corruptBytes, rssi: -80);

      await pumpEventQueue();
      expect(emittedPeers, isEmpty);

      await sub.cancel();
    });

    test('handles Android PERMISSION_DENIED on startScan gracefully', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(BleDiscoveryService.channelName),
            (call) async {
              if (call.method == 'startScan') {
                throw PlatformException(
                  code: 'PERMISSION_DENIED',
                  message: 'Missing Bluetooth scan permission',
                );
              }
              return null;
            },
          );

      final permService = BleDiscoveryService(localDeviceId: localId);
      await expectLater(
        permService.startDiscovery(),
        throwsA(isA<PlatformException>()),
      );

      expect(permService.isScanning, isFalse);
      permService.dispose();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(BleDiscoveryService.channelName),
            null,
          );
    });

    test(
      'handles Android PERMISSION_DENIED on startAdvertising gracefully',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(BleDiscoveryService.channelName),
              (call) async {
                if (call.method == 'startAdvertising') {
                  throw PlatformException(
                    code: 'PERMISSION_DENIED',
                    message: 'Missing Bluetooth advertise permission',
                  );
                }
                return null;
              },
            );

        final permService = BleDiscoveryService(localDeviceId: localId);
        const ad = DeviceAdvertisement(
          deviceId: localId,
          displayName: 'Test-Device',
          port: 53531,
          supportedTransports: {TransportType.ble},
          protocolVersion: 1,
        );

        await permService.startAdvertising(ad);
        expect(permService.isAdvertising, isFalse);
        permService.dispose();

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(BleDiscoveryService.channelName),
              null,
            );
      },
    );
  });
}
