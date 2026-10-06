import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/domain/models/peer_device.dart';

void main() {
  group('PeerDevice Tests', () {
    test('instantiates and serializes correctly', () {
      final now = DateTime.now();
      final peer = PeerDevice(
        id: 'peer-abc-123',
        displayName: 'Pixel 8',
        rssi: -55,
        availableTransports: {TransportType.ble, TransportType.wifiDirect},
        lastSeen: now,
      );

      expect(peer.id, equals('peer-abc-123'));
      expect(peer.displayName, equals('Pixel 8'));
      expect(peer.rssi, equals(-55));
      expect(peer.isPaired, isFalse);
      expect(peer.isConnected, isFalse);

      final json = peer.toJson();
      expect(json['id'], equals('peer-abc-123'));
      expect(json['availableTransports'], contains('ble'));
      expect(json['availableTransports'], contains('wifiDirect'));
    });

    test('supports copyWith for connection state updates', () {
      final now = DateTime.now();
      final peer = PeerDevice(
        id: 'peer-1',
        displayName: 'Device 1',
        rssi: -70,
        availableTransports: {TransportType.ble},
        lastSeen: now,
      );

      final connectedPeer = peer.copyWith(isConnected: true, isPaired: true);
      expect(connectedPeer.isConnected, isTrue);
      expect(connectedPeer.isPaired, isTrue);
      expect(connectedPeer.displayName, equals('Device 1'));
    });
  });
}
