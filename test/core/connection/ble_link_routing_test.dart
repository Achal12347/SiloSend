import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/ble_connection.dart';
import 'package:vayu/core/connection/ble_connection_server.dart';

/// Adapter emulating the native layer: one shared event stream for both roles.
class _FakeNativeAdapter implements BleTransportAdapter, BleClientEventSource {
  final StreamController<Map<String, dynamic>> events =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<String> disconnected = [];
  bool failConnect = false;

  @override
  Future<void> connect(String address, {int mtu = 512}) async {
    if (failConnect) {
      throw StateError('Peer does not expose the Vayu GATT service');
    }
  }

  @override
  int? negotiatedMtu(String connectionId) => 185;

  @override
  Stream<Map<String, dynamic>> clientEvents(String connectionId) => events
      .stream
      .where((e) => e['role'] == 'client' && e['connectionId'] == connectionId);

  @override
  Future<void> sendChunk(String connectionId, Uint8List chunk) async {}

  @override
  Future<void> disconnect(String connectionId) async =>
      disconnected.add(connectionId);
}

void main() {
  group('BLE event routing between client links and the GATT server', () {
    test(
      'outbound link receives its own notifications and negotiated MTU',
      () async {
        final native = _FakeNativeAdapter();
        final link = await BleConnection.connect('AA:BB', adapter: native);
        expect(link.currentMtu, 185);

        final received = link.incomingBytes.first;
        native.events.add({
          'role': 'client',
          'type': 'data',
          'connectionId': 'ble_AA:BB',
          'data': Uint8List.fromList([1, 2, 3]),
        });
        expect(await received, [1, 2, 3]);

        native.events.add({
          'role': 'client',
          'type': 'disconnected',
          'connectionId': 'ble_AA:BB',
          'reason': 'GATT disconnected',
        });
        await Future<void>.delayed(Duration.zero);
        expect(link.isConnected, isFalse);
      },
    );

    test(
      'GATT server ignores client-role events instead of inventing peers',
      () async {
        final native = _FakeNativeAdapter();
        final server = BleConnectionServer(
          customEventStream: native.events.stream,
        );
        await server.start();
        final accepted = <BleConnection>[];
        final sub = server.incomingConnections.listen(accepted.add);

        native.events.add({
          'role': 'client',
          'type': 'connected',
          'connectionId': 'ble_AA:BB',
          'remoteAddress': 'AA:BB',
          'mtu': 23,
        });
        native.events.add({
          'role': 'server',
          'type': 'connected',
          'connectionId': 'ble_server_CC:DD',
          'remoteAddress': 'CC:DD',
          'mtu': 23,
        });
        await Future<void>.delayed(Duration.zero);

        expect(accepted.map((c) => c.connectionId), ['ble_server_CC:DD']);
        await sub.cancel();
        await server.dispose();
      },
    );

    test('a failed connect releases the half-open native link', () async {
      final native = _FakeNativeAdapter()..failConnect = true;
      await expectLater(
        BleConnection.connect('AA:BB', adapter: native),
        throwsA(isA<StateError>()),
      );
      expect(native.disconnected, ['ble_AA:BB']);
    });
  });
}
