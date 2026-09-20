import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/domain/discovery/discovery_beacon.dart';

void main() {
  group('DiscoveryBeacon Tests', () {
    late Uint8List sampleDeviceId;

    setUp(() {
      sampleDeviceId = Uint8List.fromList(
        List<int>.generate(16, (i) => (i + 1) * 0x11),
      );
    });

    test('serializes and deserializes beacon correctly (roundtrip)', () {
      final original = DiscoveryBeacon(
        deviceId: sampleDeviceId,
        port: 53531,
        supportedTransports: {TransportType.lan, TransportType.ble},
        displayName: 'Pixel-8-Pro',
        protocolVersion: 1,
      );

      final encoded = original.toBytes();
      final decoded = DiscoveryBeacon.fromBytes(encoded);

      expect(decoded.deviceId, equals(original.deviceId));
      expect(decoded.deviceIdHex, equals(original.deviceIdHex));
      expect(decoded.port, equals(53531));
      expect(
        decoded.supportedTransports,
        containsAll([TransportType.lan, TransportType.ble]),
      );
      expect(decoded.displayName, equals('Pixel-8-Pro'));
      expect(decoded.protocolVersion, equals(1));
    });

    test('sanitizes and truncates oversized display names', () {
      final longName = 'A' * 50; // 50 chars > 32 max
      final beacon = DiscoveryBeacon(
        deviceId: sampleDeviceId,
        port: 53531,
        supportedTransports: {TransportType.lan},
        displayName: longName,
      );

      final encoded = beacon.toBytes();
      final decoded = DiscoveryBeacon.fromBytes(encoded);

      expect(decoded.displayName.length, equals(32));
      expect(decoded.displayName, equals('A' * 32));
    });

    test('rejects invalid magic bytes', () {
      final valid = DiscoveryBeacon(
        deviceId: sampleDeviceId,
        port: 53531,
        supportedTransports: {TransportType.lan},
        displayName: 'Device',
      ).toBytes();

      final corrupted = Uint8List.fromList(valid);
      corrupted[0] = 0x00; // Corrupt magic

      expect(() => DiscoveryBeacon.fromBytes(corrupted), throwsFormatException);
    });

    test('rejects unsupported protocol versions', () {
      final valid = DiscoveryBeacon(
        deviceId: sampleDeviceId,
        port: 53531,
        supportedTransports: {TransportType.lan},
        displayName: 'Device',
      ).toBytes();

      final corrupted = Uint8List.fromList(valid);
      corrupted[2] = 0x99; // Unknown version

      expect(() => DiscoveryBeacon.fromBytes(corrupted), throwsFormatException);
    });

    test('rejects invalid port ranges', () {
      expect(
        () => DiscoveryBeacon(
          deviceId: sampleDeviceId,
          port: 0, // Port 0 is invalid
          supportedTransports: {TransportType.lan},
          displayName: 'Device',
        ),
        throwsArgumentError,
      );
    });

    test('rejects truncated byte arrays', () {
      final valid = DiscoveryBeacon(
        deviceId: sampleDeviceId,
        port: 53531,
        supportedTransports: {TransportType.lan},
        displayName: 'Device',
      ).toBytes();

      final truncated = Uint8List.fromList(valid.sublist(0, valid.length - 3));
      expect(() => DiscoveryBeacon.fromBytes(truncated), throwsFormatException);
    });

    test('rejects corrupted payload with CRC32 mismatch', () {
      final valid = DiscoveryBeacon(
        deviceId: sampleDeviceId,
        port: 53531,
        supportedTransports: {TransportType.lan},
        displayName: 'Device',
      ).toBytes();

      final corrupted = Uint8List.fromList(valid);
      corrupted[10] ^= 0xFF; // Flip bit in device ID

      expect(() => DiscoveryBeacon.fromBytes(corrupted), throwsFormatException);
    });
  });
}
