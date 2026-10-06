import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/connection/ble_connection.dart';
import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/connection/framed_transport_connection.dart';
import 'package:vayu/core/connection/lan_connection.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/connection/handshake_payload.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/models/connection_session.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';

/// Thrown when a remote peer explicitly rejects a handshake request.
class HandshakeRejectedException implements Exception {
  final String reason;
  const HandshakeRejectedException(this.reason);

  @override
  String toString() => 'HandshakeRejectedException: $reason';
}

/// Coordinates and manages point-to-point transport connection sessions.
///
/// Responsibilities:
/// - Executes two-way handshake negotiation (handshakeInit / handshakeResponse)
/// - Automatically accepts incoming peer connections from registered transport servers
/// - Manages active session registry and maps remote device IDs to active sessions
/// - Enforces protocol compatibility and presence claims
/// - Handles graceful session teardowns and resource disposal
class ConnectionManager {
  final LocalDeviceIdentity localIdentity;
  final Set<TransportType> supportedTransports;
  final Duration handshakeTimeout;
  final Duration pingInterval;
  final Duration inactivityTimeout;

  final Map<String, ConnectionSession> _activeSessions = {};
  final Map<String, String> _deviceToSessionMap = {};
  final List<StreamSubscription<TransportConnection>> _incomingSubscriptions =
      [];

  final StreamController<ConnectionSession> _sessionEstablishedController =
      StreamController<ConnectionSession>.broadcast();
  final StreamController<String> _sessionClosedController =
      StreamController<String>.broadcast();
  final StreamController<List<ConnectionSession>>
  _activeSessionsListController =
      StreamController<List<ConnectionSession>>.broadcast();

  int _packetSequence = 1;
  bool _isDisposed = false;

  ConnectionManager({
    required this.localIdentity,
    this.supportedTransports = const {TransportType.lan},
    this.handshakeTimeout = const Duration(seconds: 10),
    this.pingInterval = ConnectionSession.defaultPingInterval,
    this.inactivityTimeout = ConnectionSession.defaultInactivityTimeout,
  });

  /// All currently active and established connection sessions.
  List<ConnectionSession> get activeSessions => _activeSessions.values.toList();

  /// Reactive stream emitting the list of active sessions whenever changes occur.
  Stream<List<ConnectionSession>> get activeSessionsStream =>
      _activeSessionsListController.stream;

  /// Stream firing whenever a new communication session is successfully established.
  Stream<ConnectionSession> get onSessionEstablished =>
      _sessionEstablishedController.stream;

  /// Stream firing the session ID whenever an active session is closed or terminated.
  Stream<String> get onSessionClosed => _sessionClosedController.stream;

  /// Retrieves an active session by its unique session ID.
  ConnectionSession? getSession(String sessionId) => _activeSessions[sessionId];

  /// Retrieves an active session with the specified remote device ID (hex).
  ConnectionSession? getSessionByDeviceId(String deviceIdHex) {
    final sessionId = _deviceToSessionMap[deviceIdHex.toLowerCase()];
    if (sessionId == null) return null;
    return _activeSessions[sessionId];
  }

  /// Whether an active session already exists with the specified remote device ID.
  bool hasSessionWithDevice(String deviceIdHex) =>
      getSessionByDeviceId(deviceIdHex) != null;

  /// Registers a LAN server to automatically accept and negotiate incoming TCP connections.
  void registerLanServer(LanConnectionServer server) {
    registerIncomingStream(server.incomingConnections);
  }

  /// Registers a stream of incoming transport connections for handshake negotiation.
  void registerIncomingStream(Stream<TransportConnection> incomingStream) {
    if (_isDisposed) return;
    final sub = incomingStream.listen(
      _handleIncomingTransport,
      onError: (e) {
        AppLogger.warning(
          'ConnectionManager',
          'Incoming transport stream error: $e',
        );
      },
    );
    _incomingSubscriptions.add(sub);
  }

  /// Connects to a discovered peer using the best available transport (LAN or BLE).
  Future<ConnectionSession> connectToPeer(
    DiscoveredPeer peer, {
    TransportType? preferredTransport,
    Duration? timeout,
  }) async {
    final transportToUse =
        preferredTransport ??
        (peer.availableTransports.contains(TransportType.lan)
            ? TransportType.lan
            : (peer.availableTransports.contains(TransportType.ble)
                  ? TransportType.ble
                  : peer.transportType));

    if (transportToUse == TransportType.lan) {
      final endpoint = peer.lanEndpoint ?? peer.endpointAddress;
      if (endpoint == null || !endpoint.contains(':')) {
        throw ArgumentError(
          'Cannot connect to LAN peer ${peer.displayName}: missing or invalid endpointAddress (${peer.endpointAddress})',
        );
      }
      final colonIndex = endpoint.lastIndexOf(':');
      final host = endpoint.substring(0, colonIndex);
      final port = int.tryParse(endpoint.substring(colonIndex + 1)) ?? 53531;

      return connectToLanPeer(
        remoteAddress: host,
        remotePort: port,
        targetDeviceId: peer.deviceId,
        timeout: timeout,
      );
    } else if (transportToUse == TransportType.ble) {
      final endpoint = peer.bleEndpoint ?? peer.endpointAddress;
      if (endpoint == null || endpoint.isEmpty) {
        throw ArgumentError(
          'Cannot connect to BLE peer ${peer.displayName}: missing endpointAddress (BLE address)',
        );
      }

      return connectToBlePeer(
        remoteAddress: endpoint,
        targetDeviceId: peer.deviceId,
        timeout: timeout,
      );
    } else {
      throw UnsupportedError(
        'Transport ${transportToUse.name} connection not supported directly via connectToPeer yet',
      );
    }
  }

  /// Outgoing: connects to a remote BLE GATT peer by address, executing the handshake negotiation.
  Future<ConnectionSession> connectToBlePeer({
    required String remoteAddress,
    String? targetDeviceId,
    Duration? timeout,
    BleTransportAdapter? bleAdapter,
  }) async {
    final effectiveTimeout = timeout ?? handshakeTimeout;
    final transport = await BleConnection.connect(
      remoteAddress,
      adapter: bleAdapter,
      timeout: effectiveTimeout,
    );

    return initiateHandshake(
      transport,
      targetDeviceId: targetDeviceId,
      timeout: effectiveTimeout,
    );
  }

  /// Outgoing: connects to a remote LAN peer by IPv4 and port, executing the handshake negotiation.
  Future<ConnectionSession> connectToLanPeer({
    required String remoteAddress,
    required int remotePort,
    String? targetDeviceId,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? handshakeTimeout;
    final transport = await LanConnection.connect(
      remoteAddress,
      remotePort,
      timeout: effectiveTimeout,
    );

    return initiateHandshake(
      transport,
      targetDeviceId: targetDeviceId,
      timeout: effectiveTimeout,
    );
  }

  /// Outgoing: initiates handshake negotiation over an existing [TransportConnection].
  Future<ConnectionSession> initiateHandshake(
    TransportConnection transport, {
    String? targetDeviceId,
    Duration? timeout,
  }) async {
    if (_isDisposed) {
      await transport.close(reason: 'manager_disposed');
      throw StateError('ConnectionManager is disposed');
    }

    final effectiveTimeout = timeout ?? handshakeTimeout;
    final framed = FramedTransportConnection(transport);
    final sessionId = generateSessionId();

    AppLogger.info(
      'ConnectionManager',
      'Initiating handshake with ${transport.remoteAddress}:${transport.remotePort} (session: $sessionId)',
    );

    final handshakePayload = HandshakePayload(
      protocolVersion: localIdentity.protocolVersion,
      sessionId: sessionId,
      deviceIdHex: localIdentity.idHex,
      displayName: localIdentity.displayName,
      platform: localIdentity.platform,
      supportedTransports: supportedTransports,
      accepted: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    final destinationBytes =
        targetDeviceId != null && targetDeviceId.length == 32
        ? _parseHexToBytes(targetDeviceId)
        : Uint8List(16); // Wildcard / unknown destination before handshake

    final initPacket = VayuPacket(
      packetType: PacketType.handshakeInit,
      packetId: _nextPacketId(),
      sourceDeviceId: localIdentity.deviceId,
      destinationDeviceId: destinationBytes,
      payload: handshakePayload.toBytes(),
    );

    try {
      await framed.sendPacket(initPacket);

      // Await handshake response
      final responsePacket = await framed.incomingPackets
          .firstWhere((p) => p.packetType == PacketType.handshakeResponse)
          .timeout(effectiveTimeout);

      final responsePayload = HandshakePayload.fromBytes(
        responsePacket.payload,
      );

      if (!responsePayload.accepted) {
        final reason =
            responsePayload.rejectionReason ?? 'Handshake rejected by peer';
        AppLogger.warning(
          'ConnectionManager',
          'Handshake rejected by peer ${responsePayload.deviceIdHex}: $reason',
        );
        await framed.close(reason: 'handshake_rejected');
        throw HandshakeRejectedException(reason);
      }

      if (responsePayload.protocolVersion != localIdentity.protocolVersion) {
        final error =
            'Incompatible protocol version (local: ${localIdentity.protocolVersion}, remote: ${responsePayload.protocolVersion})';
        AppLogger.warning('ConnectionManager', error);
        await framed.close(reason: 'protocol_version_mismatch');
        throw FormatException(error);
      }

      return _registerSession(
        sessionId: sessionId,
        remoteDeviceIdHex: responsePayload.deviceIdHex,
        remoteDisplayName: responsePayload.displayName,
        remotePlatform: responsePayload.platform,
        transport: transport,
        framed: framed,
        isInitiator: true,
      );
    } catch (e) {
      await framed.close(reason: 'handshake_failed');
      rethrow;
    }
  }

  /// Incoming: handles an incoming transport connection, awaiting handshakeInit and responding.
  Future<void> _handleIncomingTransport(TransportConnection transport) async {
    if (_isDisposed) {
      await transport.close(reason: 'manager_disposed');
      return;
    }

    final framed = FramedTransportConnection(transport);
    AppLogger.info(
      'ConnectionManager',
      'Awaiting handshake from ${transport.remoteAddress}:${transport.remotePort}',
    );

    try {
      final initPacket = await framed.incomingPackets
          .firstWhere((p) => p.packetType == PacketType.handshakeInit)
          .timeout(handshakeTimeout);

      final initPayload = HandshakePayload.fromBytes(initPacket.payload);

      // Verify protocol version
      if (initPayload.protocolVersion != localIdentity.protocolVersion) {
        AppLogger.warning(
          'ConnectionManager',
          'Rejecting handshake: protocol version mismatch (${initPayload.protocolVersion})',
        );
        final rejectPayload = HandshakePayload(
          protocolVersion: localIdentity.protocolVersion,
          sessionId: initPayload.sessionId,
          deviceIdHex: localIdentity.idHex,
          displayName: localIdentity.displayName,
          platform: localIdentity.platform,
          supportedTransports: supportedTransports,
          accepted: false,
          rejectionReason: 'unsupported_protocol_version',
        );

        final rejectPacket = VayuPacket(
          packetType: PacketType.handshakeResponse,
          packetId: _nextPacketId(),
          sourceDeviceId: localIdentity.deviceId,
          destinationDeviceId: initPayload.deviceIdBytes,
          payload: rejectPayload.toBytes(),
        );

        try {
          await framed.sendPacket(rejectPacket);
        } finally {
          await framed.close(reason: 'protocol_version_mismatch');
        }
        return;
      }

      // Accept handshake
      final acceptPayload = HandshakePayload(
        protocolVersion: localIdentity.protocolVersion,
        sessionId: initPayload.sessionId,
        deviceIdHex: localIdentity.idHex,
        displayName: localIdentity.displayName,
        platform: localIdentity.platform,
        supportedTransports: supportedTransports,
        accepted: true,
      );

      final acceptPacket = VayuPacket(
        packetType: PacketType.handshakeResponse,
        packetId: _nextPacketId(),
        sourceDeviceId: localIdentity.deviceId,
        destinationDeviceId: initPayload.deviceIdBytes,
        payload: acceptPayload.toBytes(),
      );

      await framed.sendPacket(acceptPacket);

      _registerSession(
        sessionId: initPayload.sessionId,
        remoteDeviceIdHex: initPayload.deviceIdHex,
        remoteDisplayName: initPayload.displayName,
        remotePlatform: initPayload.platform,
        transport: transport,
        framed: framed,
        isInitiator: false,
      );
    } catch (e) {
      AppLogger.warning(
        'ConnectionManager',
        'Failed to complete incoming handshake: $e',
      );
      await framed.close(reason: 'handshake_failed');
    }
  }

  ConnectionSession _registerSession({
    required String sessionId,
    required String remoteDeviceIdHex,
    required String remoteDisplayName,
    required String remotePlatform,
    required TransportConnection transport,
    required FramedTransportConnection framed,
    bool isInitiator = false,
  }) {
    final normalizedRemoteId = remoteDeviceIdHex.toLowerCase();

    // Close any previous session with the same device
    final existingSessionId = _deviceToSessionMap[normalizedRemoteId];
    if (existingSessionId != null &&
        _activeSessions.containsKey(existingSessionId)) {
      AppLogger.info(
        'ConnectionManager',
        'Superseding existing session $existingSessionId with $remoteDeviceIdHex',
      );
      disconnectSession(existingSessionId, reason: 'superseded');
    }

    final info = ConnectionSessionInfo(
      sessionId: sessionId,
      remoteDeviceId: normalizedRemoteId,
      remoteDisplayName: remoteDisplayName,
      remotePlatform: remotePlatform,
      activeTransport: transport.type,
      state: SessionState.connected,
      establishedAt: DateTime.now(),
      remoteAddress: transport.remoteAddress,
      remotePort: transport.remotePort,
      isInitiator: isInitiator,
    );

    final session = ConnectionSession(
      info: info,
      connection: framed,
      localIdentity: localIdentity,
      pingInterval: pingInterval,
      inactivityTimeout: inactivityTimeout,
      onClosed: _onSessionClosed,
    );

    // Listen to session state transitions (e.g. SessionState.secured) and emit updated active sessions
    session.stateChanges.listen((_) {
      if (!_activeSessionsListController.isClosed) {
        _activeSessionsListController.add(activeSessions);
      }
    });

    _activeSessions[sessionId] = session;
    _deviceToSessionMap[normalizedRemoteId] = sessionId;

    AppLogger.info(
      'ConnectionManager',
      'Session established: $sessionId with peer $remoteDisplayName ($normalizedRemoteId) over ${transport.type.name}',
    );

    if (!_sessionEstablishedController.isClosed) {
      _sessionEstablishedController.add(session);
    }
    if (!_activeSessionsListController.isClosed) {
      _activeSessionsListController.add(activeSessions);
    }

    return session;
  }

  void _onSessionClosed(ConnectionSession session, String reason) {
    final sessionId = session.sessionId;
    final remoteId = session.remoteDeviceId.toLowerCase();

    _activeSessions.remove(sessionId);
    if (_deviceToSessionMap[remoteId] == sessionId) {
      _deviceToSessionMap.remove(remoteId);
    }

    AppLogger.info(
      'ConnectionManager',
      'Session $sessionId closed ($reason). Active remaining: ${_activeSessions.length}',
    );

    if (!_sessionClosedController.isClosed) {
      _sessionClosedController.add(sessionId);
    }
    if (!_activeSessionsListController.isClosed) {
      _activeSessionsListController.add(activeSessions);
    }
  }

  /// Explicitly disconnects an active session with the given session ID.
  Future<void> disconnectSession(String sessionId, {String? reason}) async {
    final session = _activeSessions[sessionId];
    if (session != null) {
      await session.close(reason: reason ?? 'user_disconnect');
    }
  }

  /// Generates a cryptographically random 16-byte (32-char hex) session ID.
  static String generateSessionId() {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  int _nextPacketId() => _packetSequence++;

  static Uint8List _parseHexToBytes(String hex) {
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// Disposes the connection manager, closing all active sessions and canceling subscriptions.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    for (final sub in _incomingSubscriptions) {
      await sub.cancel();
    }
    _incomingSubscriptions.clear();

    final sessions = _activeSessions.values.toList();
    for (final session in sessions) {
      await session.close(reason: 'manager_disposed');
    }
    _activeSessions.clear();
    _deviceToSessionMap.clear();

    if (!_sessionEstablishedController.isClosed) {
      await _sessionEstablishedController.close();
    }
    if (!_sessionClosedController.isClosed) {
      await _sessionClosedController.close();
    }
    if (!_activeSessionsListController.isClosed) {
      await _activeSessionsListController.close();
    }
  }
}
