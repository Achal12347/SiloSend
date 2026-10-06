import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/ble_connection.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

class _MockBleTransportAdapter implements BleTransportAdapter {
  final List<Uint8List> sentChunks = [];
  bool connectCalled = false;
  bool disconnectCalled = false;

  @override
  Future<void> connect(String address, {int mtu = 512}) async {
    connectCalled = true;
  }

  @override
  Future<void> sendChunk(String connectionId, Uint8List chunk) async {
    sentChunks.add(chunk);
  }

  @override
  Future<void> disconnect(String connectionId) async {
    disconnectCalled = true;
  }
}

void main() {
  group('BleConnection Outbound Connection Tests', () {
    test(
      'BleConnection.connect successfully invokes adapter and initializes link',
      () async {
        final adapter = _MockBleTransportAdapter();
        final connection = await BleConnection.connect(
          '11:22:33:44:55:66',
          adapter: adapter,
        );

        expect(adapter.connectCalled, isTrue);
        expect(connection.remoteAddress, '11:22:33:44:55:66');
        expect(connection.type, TransportType.ble);
        expect(connection.isConnected, isTrue);

        await connection.close();
        expect(adapter.disconnectCalled, isTrue);
        expect(connection.isConnected, isFalse);
      },
    );

    test('ConnectionManager.connectToBlePeer establishes transport and initiates handshake packet', () async {
      final localIdentity = LocalDeviceIdentity.generate(
        displayName: 'Local Initiator',
        platform: 'android',
      );
      final manager = ConnectionManager(
        localIdentity: localIdentity,
        supportedTransports: {TransportType.ble},
      );

      final adapter = _MockBleTransportAdapter();

      // Launch connectToBlePeer asynchronously
      final futureSession = manager.connectToBlePeer(
        remoteAddress: 'AA:BB:CC:DD:EE:FF',
        targetDeviceId: '00112233445566778899aabbccddeeff',
        timeout: const Duration(seconds: 2),
        bleAdapter: adapter,
      );

      // Verify adapter connect was called
      expect(adapter.connectCalled, isTrue);

      // Verify that the initiator sent out the HandshakeInit packet
      await Future.delayed(const Duration(milliseconds: 50));
      expect(adapter.sentChunks, isNotEmpty);

      // Dispose manager
      manager.dispose();
      expect(futureSession, throwsA(anything));
    });
  });
}
