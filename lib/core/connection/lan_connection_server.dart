import 'dart:async';
import 'dart:io';

import 'package:vayu/core/connection/lan_connection.dart';
import 'package:vayu/core/logging/app_logger.dart';

/// Manages an IPv4 TCP server socket accepting incoming connections from remote Vayu peers.
class LanConnectionServer {
  static const int defaultPort = 53531;

  final int requestedPort;
  ServerSocket? _serverSocket;
  final StreamController<LanConnection> _connectionController =
      StreamController<LanConnection>.broadcast();

  bool _isRunning = false;

  LanConnectionServer({this.requestedPort = defaultPort});

  bool get isRunning => _isRunning;

  int get boundPort => _serverSocket?.port ?? requestedPort;

  Stream<LanConnection> get incomingConnections => _connectionController.stream;

  /// Starts listening for incoming TCP connections.
  Future<void> start() async {
    if (_isRunning) return;

    try {
      _serverSocket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        requestedPort,
        shared: false,
      );
      _isRunning = true;
      AppLogger.info(
        'LanConnectionServer',
        'Listening for peer connections on port ${_serverSocket!.port}',
      );

      _serverSocket!.listen(
        (clientSocket) {
          try {
            final connection = LanConnection.fromSocket(clientSocket);
            AppLogger.info(
              'LanConnectionServer',
              'Accepted incoming TCP connection from ${connection.remoteAddress}:${connection.remotePort}',
            );
            if (!_connectionController.isClosed) {
              _connectionController.add(connection);
            }
          } catch (e) {
            AppLogger.error(
              'LanConnectionServer',
              'Error accepting incoming client socket',
              error: e,
            );
          }
        },
        onError: (e) {
          AppLogger.error(
            'LanConnectionServer',
            'Server socket error',
            error: e,
          );
        },
        cancelOnError: false,
      );
    } catch (e, stack) {
      AppLogger.error(
        'LanConnectionServer',
        'Failed to bind server socket on port $requestedPort',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Stops the server socket and closes the incoming connections stream.
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;

    try {
      await _serverSocket?.close();
      _serverSocket = null;
      AppLogger.info('LanConnectionServer', 'Server socket stopped');
    } catch (e) {
      AppLogger.warning(
        'LanConnectionServer',
        'Error closing server socket: $e',
      );
    }
  }

  /// Disposes active resources.
  Future<void> dispose() async {
    await stop();
    if (!_connectionController.isClosed) {
      await _connectionController.close();
    }
  }
}
