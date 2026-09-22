import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/logging/app_logger.dart';

/// Pure Dart implementation of [TransportConnection] over an IPv4 TCP [Socket].
class LanConnection implements TransportConnection {
  final Socket _socket;
  final String _connectionId;
  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();

  ConnectionState _state = ConnectionState.connected;
  String? _disconnectReason;
  StreamSubscription<Uint8List>? _socketSub;

  int _bytesSent = 0;
  int _bytesReceived = 0;
  final DateTime _connectedAt = DateTime.now();

  LanConnection._(this._socket, this._connectionId) {
    _socketSub = _socket.listen(
      (data) {
        _bytesReceived += data.length;
        if (!_incomingController.isClosed) {
          _incomingController.add(data);
        }
      },
      onError: (e) {
        AppLogger.error(
          'LanConnection',
          'Socket stream error on $_connectionId',
          error: e,
        );
        close(reason: 'Socket error: $e');
      },
      onDone: () {
        AppLogger.info(
          'LanConnection',
          'Socket closed by peer on $_connectionId',
        );
        close(reason: 'Closed by peer');
      },
      cancelOnError: true,
    );
  }

  /// Connects to a remote peer via IPv4 TCP socket.
  static Future<LanConnection> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);

    final connectionId =
        'lan_${socket.remoteAddress.address}_${socket.remotePort}_${DateTime.now().millisecondsSinceEpoch}';
    return LanConnection._(socket, connectionId);
  }

  /// Wraps an accepted incoming client socket from [ServerSocket].
  factory LanConnection.fromSocket(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final connectionId =
        'lan_in_${socket.remoteAddress.address}_${socket.remotePort}_${DateTime.now().millisecondsSinceEpoch}';
    return LanConnection._(socket, connectionId);
  }

  @override
  String get connectionId => _connectionId;

  @override
  TransportType get type => TransportType.lan;

  @override
  ConnectionState get state => _state;

  @override
  bool get isConnected => _state == ConnectionState.connected;

  @override
  String? get remoteAddress => _socket.remoteAddress.address;

  @override
  int? get remotePort => _socket.remotePort;

  @override
  String? get disconnectReason => _disconnectReason;

  @override
  Stream<Uint8List> get incomingBytes => _incomingController.stream;

  Future<void>? _sendQueue;

  @override
  Future<void> sendBytes(Uint8List data) async {
    if (!isConnected) {
      throw StateError('Cannot send bytes: connection is in state $_state');
    }
    final prev = _sendQueue;
    final c = Completer<void>();
    _sendQueue = c.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }

    try {
      if (!isConnected) {
        throw StateError('Cannot send bytes: connection is in state $_state');
      }
      _socket.add(data);
      await _socket.flush();
      _bytesSent += data.length;
    } finally {
      c.complete();
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
      await _socketSub?.cancel();
      _socketSub = null;
      await _socket.close();
      _socket.destroy();
    } catch (e) {
      AppLogger.warning('LanConnection', 'Error destroying socket: $e');
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
    final throughput = durationSec > 0
        ? ((_bytesSent + _bytesReceived) ~/ durationSec)
        : (_bytesSent + _bytesReceived);

    return LinkMetrics(
      latencyMs: 1, // Wired/LAN latency baseline
      estimatedThroughputBytesPerSec: throughput,
      rssi: 0,
    );
  }
}
