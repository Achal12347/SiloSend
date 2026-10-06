import 'dart:async';

import 'package:flutter/services.dart';
import 'package:vayu/core/connection/ble_packet_slicer.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';

/// Pluggable interface for invoking native BLE GATT transport operations.
abstract class BleTransportAdapter {
  Future<void> connect(String address, {int mtu = 512});
  Future<void> sendChunk(String connectionId, Uint8List chunk);
  Future<void> disconnect(String connectionId);
}

/// Default implementation delegating to the native Flutter platform MethodChannel.
class PlatformBleTransportAdapter implements BleTransportAdapter {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/ble_connection',
  );

  @override
  Future<void> connect(String address, {int mtu = 512}) async {
    await _channel.invokeMethod('connect', {'address': address, 'mtu': mtu});
  }

  @override
  Future<void> sendChunk(String connectionId, Uint8List chunk) async {
    await _channel.invokeMethod('sendBytes', {
      'connectionId': connectionId,
      'data': chunk,
    });
  }

  @override
  Future<void> disconnect(String connectionId) async {
    await _channel.invokeMethod('disconnect', {'connectionId': connectionId});
  }
}

/// Bidirectional point-to-point [TransportConnection] for Bluetooth Low Energy GATT links.
///
/// Ensures strict ATT-MTU safety:
/// - Tracks the negotiated ATT MTU dynamically (default 23 bytes, up to 512 bytes).
/// - Automatically slices outgoing data into MTU-safe chunks prior to transmission.
/// - Ingests incoming MTU fragments into [incomingBytes] for upstream frame reassembly.
class BleConnection implements TransportConnection {
  @override
  final String connectionId;
  @override
  final String remoteAddress;

  final BleTransportAdapter _adapter;
  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();

  ConnectionState _state = ConnectionState.connected;
  String? _disconnectReason;
  int _currentMtu;
  int _bytesSent = 0;
  int _bytesReceived = 0;
  final DateTime _connectedAt = DateTime.now();

  BleConnection({
    required this.connectionId,
    required this.remoteAddress,
    int initialMtu = BlePacketSlicer.defaultAttMtu,
    BleTransportAdapter? adapter,
  }) : _currentMtu = initialMtu,
       _adapter = adapter ?? PlatformBleTransportAdapter();

  /// Connects to a remote BLE GATT server and returns an active [BleConnection].
  static Future<BleConnection> connect(
    String remoteAddress, {
    int requestedMtu = 512,
    BleTransportAdapter? adapter,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final effectiveAdapter = adapter ?? PlatformBleTransportAdapter();
    final connectionId = 'ble_$remoteAddress';

    await effectiveAdapter
        .connect(remoteAddress, mtu: requestedMtu)
        .timeout(
          timeout,
          onTimeout: () {
            throw TimeoutException(
              'Timed out connecting to BLE peer at $remoteAddress',
            );
          },
        );

    return BleConnection(
      connectionId: connectionId,
      remoteAddress: remoteAddress,
      initialMtu: requestedMtu,
      adapter: effectiveAdapter,
    );
  }

  @override
  TransportType get type => TransportType.ble;

  @override
  ConnectionState get state => _state;

  @override
  bool get isConnected => _state == ConnectionState.connected;

  @override
  int? get remotePort => null; // Port concept does not apply to BLE GATT

  @override
  String? get disconnectReason => _disconnectReason;

  @override
  Stream<Uint8List> get incomingBytes => _incomingController.stream;

  /// The current negotiated ATT MTU for this GATT connection.
  int get currentMtu => _currentMtu;

  /// The maximum payload bytes that can safely fit inside a single ATT write/notify packet.
  int get effectivePayloadSize =>
      BlePacketSlicer.computeEffectivePayload(_currentMtu);

  /// Updates the negotiated ATT MTU dynamically when the OS fires `onMtuChanged`.
  void handleMtuChanged(int newMtu) {
    if (newMtu >= BlePacketSlicer.defaultAttMtu) {
      _currentMtu = newMtu;
      AppLogger.info(
        'BleConnection',
        'Updated MTU for $connectionId to $_currentMtu (effective payload: $effectivePayloadSize bytes)',
      );
    }
  }

  /// Ingests incoming raw data chunk received from the native BLE event channel.
  void handleIncomingBytes(Uint8List chunk) {
    if (!isConnected) return;
    _bytesReceived += chunk.length;
    if (!_incomingController.isClosed) {
      _incomingController.add(chunk);
    }
  }

  /// Handles peer disconnection event emitted from the native platform.
  void handlePeerDisconnected(String? reason) {
    if (_state == ConnectionState.disconnected) return;
    _state = ConnectionState.disconnected;
    _disconnectReason = reason ?? 'BLE GATT disconnected by peer';
    if (!_incomingController.isClosed) {
      _incomingController.close();
    }
  }

  @override
  Future<void> sendBytes(Uint8List data) async {
    if (!isConnected) {
      throw StateError(
        'Cannot send bytes: BLE connection $connectionId in state $_state',
      );
    }

    try {
      // Slice outgoing buffer into ATT-MTU safe chunks
      final chunks = BlePacketSlicer.slice(data, mtu: _currentMtu);
      for (final chunk in chunks) {
        if (!isConnected) {
          throw StateError('BLE connection lost while sending MTU chunks');
        }
        await _adapter.sendChunk(connectionId, chunk);
        _bytesSent += chunk.length;
      }
    } catch (e) {
      AppLogger.error(
        'BleConnection',
        'Failed to send BLE bytes on $connectionId',
        error: e,
      );
      rethrow;
    }
  }

  @override
  Future<void> close({String? reason}) async {
    if (_state == ConnectionState.disconnected ||
        _state == ConnectionState.disconnecting) {
      return;
    }

    _state = ConnectionState.disconnecting;
    _disconnectReason = reason ?? 'Connection closed';

    try {
      await _adapter.disconnect(connectionId);
    } catch (e) {
      AppLogger.warning('BleConnection', 'Error during BLE disconnect: $e');
    } finally {
      _state = ConnectionState.disconnected;
      if (!_incomingController.isClosed) {
        await _incomingController.close();
      }
    }
  }

  @override
  LinkMetrics get currentMetrics {
    final durationSec = DateTime.now().difference(_connectedAt).inSeconds;
    final totalBytes = _bytesSent + _bytesReceived;
    final throughput = durationSec > 0
        ? (totalBytes ~/ durationSec)
        : totalBytes;

    return LinkMetrics(
      latencyMs: 45, // Typical BLE 4.2/5.0 connection interval latency
      estimatedThroughputBytesPerSec: throughput,
      rssi: -65,
    );
  }
}
