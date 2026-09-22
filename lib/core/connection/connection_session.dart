import 'dart:async';
import 'dart:typed_data';

import 'package:silosend_datasharing_app/core/connection/framed_transport_connection.dart';
import 'package:silosend_datasharing_app/core/contracts/security_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/logging/app_logger.dart';
import 'package:silosend_datasharing_app/domain/identity/local_device_identity.dart';
import 'package:silosend_datasharing_app/domain/models/connection_session.dart';
import 'package:silosend_datasharing_app/domain/protocol/packet_type.dart';
import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';

/// Manages an active, established transport connection session with a remote SiloSend peer.
///
/// Handles packet routing, automatic keepalive pings/pongs, inactivity detection,
/// metrics tracking, and graceful session teardown.
class ConnectionSession {
  static const Duration defaultPingInterval = Duration(seconds: 15);
  static const Duration defaultInactivityTimeout = Duration(seconds: 45);

  final FramedTransportConnection connection;
  final LocalDeviceIdentity localIdentity;
  final Duration pingInterval;
  final Duration inactivityTimeout;
  final void Function(ConnectionSession session, String reason)?
  _onClosedCallback;

  ConnectionSessionInfo _info;
  late final Uint8List _remoteDeviceIdBytes;

  final StreamController<SiloSendPacket> _incomingPacketsController =
      StreamController<SiloSendPacket>.broadcast();
  final StreamController<ConnectionSessionInfo> _stateController =
      StreamController<ConnectionSessionInfo>.broadcast();

  StreamSubscription<SiloSendPacket>? _packetSubscription;
  Timer? _heartbeatTimer;
  DateTime _lastActivity;
  int _packetSequence = 1;
  bool _isDisposed = false;

  ConnectionSession({
    required ConnectionSessionInfo info,
    required this.connection,
    required this.localIdentity,
    this.pingInterval = defaultPingInterval,
    this.inactivityTimeout = defaultInactivityTimeout,
    void Function(ConnectionSession session, String reason)? onClosed,
  }) : _info = info,
       _onClosedCallback = onClosed,
       _lastActivity = DateTime.now() {
    _remoteDeviceIdBytes = _parseHexToBytes(info.remoteDeviceId);
    _init();
  }

  ConnectionSessionInfo get info => _info;
  String get sessionId => _info.sessionId;
  String get remoteDeviceId => _info.remoteDeviceId;
  SessionState get state => _info.state;
  bool get isInitiator => _info.isInitiator;
  bool get isActive =>
      (_info.state == SessionState.connected ||
          _info.state == SessionState.secured) &&
      !_isDisposed;
  LinkMetrics get currentMetrics => connection.currentMetrics;

  Stream<SiloSendPacket> get incomingPackets =>
      _incomingPacketsController.stream;
  Stream<ConnectionSessionInfo> get stateChanges => _stateController.stream;

  void _init() {
    _packetSubscription = connection.incomingPackets.listen(
      _handleIncomingPacket,
      onError: (e) {
        AppLogger.warning(
          'ConnectionSession',
          'Session $sessionId transport error: $e',
        );
        close(reason: 'transport_error');
      },
      onDone: () {
        AppLogger.info(
          'ConnectionSession',
          'Session $sessionId transport completed',
        );
        close(reason: 'transport_closed', sendTeardownPacket: false);
      },
      cancelOnError: true,
    );

    _startHeartbeatTimer();
  }

  void _handleIncomingPacket(SiloSendPacket packet) {
    _lastActivity = DateTime.now();
    _updateMetrics(bytesReceivedDelta: packet.payload.length);

    switch (packet.packetType) {
      case PacketType.ping:
        AppLogger.debug(
          'ConnectionSession',
          'Received ping from $remoteDeviceId',
        );
        _sendPong(packet.packetId);
        break;

      case PacketType.pong:
        AppLogger.debug(
          'ConnectionSession',
          'Received pong from $remoteDeviceId',
        );
        break;

      case PacketType.sessionTeardown:
        AppLogger.info(
          'ConnectionSession',
          'Received session teardown from $remoteDeviceId',
        );
        close(reason: 'remote_teardown', sendTeardownPacket: false);
        break;

      default:
        // Application / transport data packet
        if (!_incomingPacketsController.isClosed) {
          _incomingPacketsController.add(packet);
        }
        break;
    }
  }

  void _startHeartbeatTimer() {
    // Check periodically at half the ping interval or every 5 seconds
    final checkPeriod = Duration(
      milliseconds: (pingInterval.inMilliseconds / 2)
          .clamp(1000, 15000)
          .toInt(),
    );

    _heartbeatTimer = Timer.periodic(checkPeriod, (timer) {
      if (!isActive) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final silenceDuration = now.difference(_lastActivity);

      // Inactivity timeout
      if (silenceDuration >= inactivityTimeout) {
        AppLogger.warning(
          'ConnectionSession',
          'Session $sessionId timed out after ${silenceDuration.inSeconds}s of inactivity',
        );
        close(reason: 'inactivity_timeout');
        return;
      }

      // Keepalive ping
      if (silenceDuration >= pingInterval) {
        _sendPing();
      }
    });
  }

  Future<void> _sendPing() async {
    try {
      final packet = SiloSendPacket(
        packetType: PacketType.ping,
        packetId: _nextPacketId(),
        sourceDeviceId: localIdentity.deviceId,
        destinationDeviceId: _remoteDeviceIdBytes,
        payload: Uint8List(0),
      );
      await connection.sendPacket(packet);
    } catch (e) {
      AppLogger.warning(
        'ConnectionSession',
        'Failed to send ping on session $sessionId: $e',
      );
    }
  }

  Future<void> _sendPong(int requestPacketId) async {
    try {
      final packet = SiloSendPacket(
        packetType: PacketType.pong,
        packetId: requestPacketId,
        sourceDeviceId: localIdentity.deviceId,
        destinationDeviceId: _remoteDeviceIdBytes,
        payload: Uint8List(0),
      );
      await connection.sendPacket(packet);
    } catch (e) {
      AppLogger.warning(
        'ConnectionSession',
        'Failed to send pong on session $sessionId: $e',
      );
    }
  }

  /// Sends a data packet across this session link.
  Future<void> sendPacket(SiloSendPacket packet) async {
    if (!isActive) {
      throw StateError(
        'Cannot send packet on inactive session $sessionId (state: $state)',
      );
    }

    await connection.sendPacket(packet);
    _lastActivity = DateTime.now();
    _updateMetrics(bytesSentDelta: packet.payload.length);
  }

  /// Gracefully tears down this session and closes the underlying transport link.
  Future<void> close({String? reason, bool sendTeardownPacket = true}) async {
    if (_isDisposed) return;
    _isDisposed = true;

    final effectiveReason = reason ?? 'closed';
    AppLogger.info(
      'ConnectionSession',
      'Closing session $sessionId: $effectiveReason',
    );

    _updateState(SessionState.closing);

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (sendTeardownPacket && connection.isConnected) {
      try {
        final teardownPacket = SiloSendPacket(
          packetType: PacketType.sessionTeardown,
          packetId: _nextPacketId(),
          sourceDeviceId: localIdentity.deviceId,
          destinationDeviceId: _remoteDeviceIdBytes,
          payload: Uint8List(0),
        );
        await connection.sendPacket(teardownPacket);
      } catch (e) {
        AppLogger.warning(
          'ConnectionSession',
          'Failed to send teardown packet on $sessionId: $e',
        );
      }
    }

    await _packetSubscription?.cancel();
    _packetSubscription = null;

    try {
      await connection.close(reason: effectiveReason);
    } catch (e) {
      AppLogger.warning(
        'ConnectionSession',
        'Error closing transport connection for $sessionId: $e',
      );
    }

    _updateState(SessionState.closed);

    if (!_incomingPacketsController.isClosed) {
      await _incomingPacketsController.close();
    }

    _onClosedCallback?.call(this, effectiveReason);

    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }

  /// Updates the lifecycle state of this connection session.
  void updateState(SessionState newState) {
    _updateState(newState);
  }

  void _updateState(SessionState newState) {
    if (_info.state == newState) return;
    _info = _info.copyWith(state: newState);
    if (!_stateController.isClosed) {
      _stateController.add(_info);
    }
  }

  void _updateMetrics({int bytesSentDelta = 0, int bytesReceivedDelta = 0}) {
    _info = _info.copyWith(
      bytesSent: _info.bytesSent + bytesSentDelta,
      bytesReceived: _info.bytesReceived + bytesReceivedDelta,
    );
    if (!_stateController.isClosed) {
      _stateController.add(_info);
    }
  }

  int _nextPacketId() => _packetSequence++;

  static Uint8List _parseHexToBytes(String hex) {
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
