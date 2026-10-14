import 'dart:async';

import 'package:flutter/services.dart';
import 'package:vayu/core/connection/ble_connection.dart';
import 'package:vayu/core/logging/app_logger.dart';

/// Manages a native Bluetooth Low Energy GATT Server accepting incoming peer connections.
///
/// Listens to native GATT server lifecycle and characteristic write events,
/// instantiating [BleConnection] instances and forwarding ATT chunks.
class BleConnectionServer {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.achyrio.vayu/ble_connection',
  );

  final Stream<dynamic>? customEventStream;
  final BleTransportAdapter? customAdapter;

  final Map<String, BleConnection> _activeConnections = {};
  final StreamController<BleConnection> _connectionController =
      StreamController<BleConnection>.broadcast();

  StreamSubscription<dynamic>? _eventSubscription;
  bool _isRunning = false;

  BleConnectionServer({this.customEventStream, this.customAdapter});

  bool get isRunning => _isRunning;

  /// Stream of established incoming BLE GATT connections.
  Stream<BleConnection> get incomingConnections => _connectionController.stream;

  /// Starts the native GATT Server and begins listening for peer connection events.
  Future<void> start() async {
    if (_isRunning) return;

    try {
      if (customEventStream == null) {
        await _methodChannel.invokeMethod('startServer');
      }

      // Shared stream: a separate receiveBroadcastStream() would replace the
      // native sink and starve outbound links.
      final stream = customEventStream ?? BlePlatformEvents.stream;
      _eventSubscription = stream.listen(
        _handlePlatformEvent,
        onError: (e) {
          AppLogger.error(
            'BleConnectionServer',
            'Event channel error',
            error: e,
          );
        },
      );

      _isRunning = true;
      AppLogger.info('BleConnectionServer', 'GATT Server started successfully');
    } catch (e) {
      AppLogger.error(
        'BleConnectionServer',
        'Failed to start GATT server',
        error: e,
      );
      rethrow;
    }
  }

  void _handlePlatformEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;
    final event = Map<String, dynamic>.from(rawEvent);
    // Outbound (client) links route their own events.
    if (event['role'] == 'client') return;
    final type = event['type'] as String?;
    final connectionId = event['connectionId'] as String?;

    if (type == null || connectionId == null) return;

    switch (type) {
      case 'connected':
        final remoteAddress = event['remoteAddress'] as String? ?? 'unknown';
        final mtu = event['mtu'] as int? ?? 23;

        final connection = BleConnection(
          connectionId: connectionId,
          remoteAddress: remoteAddress,
          initialMtu: mtu,
          adapter: customAdapter,
        );

        _activeConnections[connectionId] = connection;
        AppLogger.info(
          'BleConnectionServer',
          'Incoming BLE peer connected: $connectionId ($remoteAddress, MTU: $mtu)',
        );

        if (!_connectionController.isClosed) {
          _connectionController.add(connection);
        }
        break;

      case 'data':
        final data = event['data'];
        if (data != null) {
          final connection = _activeConnections[connectionId];
          if (connection != null) {
            final bytes = data is Uint8List
                ? data
                : Uint8List.fromList(List<int>.from(data as List));
            connection.handleIncomingBytes(bytes);
          }
        }
        break;

      case 'mtuChanged':
        final mtu = event['mtu'] as int?;
        if (mtu != null) {
          _activeConnections[connectionId]?.handleMtuChanged(mtu);
        }
        break;

      case 'disconnected':
        final reason = event['reason'] as String?;
        final connection = _activeConnections.remove(connectionId);
        connection?.handlePeerDisconnected(reason);
        AppLogger.info(
          'BleConnectionServer',
          'BLE peer disconnected: $connectionId ($reason)',
        );
        break;
    }
  }

  /// Stops the GATT Server and releases platform radio resources.
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;

    await _eventSubscription?.cancel();
    _eventSubscription = null;

    final connections = _activeConnections.values.toList();
    for (final conn in connections) {
      await conn.close(reason: 'server_stopped');
    }
    _activeConnections.clear();

    try {
      if (customEventStream == null) {
        await _methodChannel.invokeMethod('stopServer');
      }
      AppLogger.info('BleConnectionServer', 'GATT Server stopped');
    } catch (e) {
      AppLogger.warning(
        'BleConnectionServer',
        'Error stopping GATT server: $e',
      );
    }
  }

  /// Disposes active resources and closes stream controllers.
  Future<void> dispose() async {
    await stop();
    if (!_connectionController.isClosed) {
      await _connectionController.close();
    }
  }
}
