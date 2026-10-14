import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transfer/consent_registry.dart';
import 'package:vayu/core/transfer/transfer_stats.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/transfer/payload_destination.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

/// Concrete implementation of [TransferEngine] managing active, multiplexed file
/// and data transfers end-to-end over authenticated [SecureSession] instances.
class TransferEngineImpl implements TransferEngine {
  final String localDeviceId;
  final SecureSessionManager? secureSessionManager;
  final SecureSession? Function(String remoteDeviceId)? sessionResolver;

  /// Receiver-side consent for batch offers this device accepted.
  final ConsentRegistry consentRegistry;

  /// Answers whether a peer advertised a protocol feature in its handshake.
  /// Defaults to reading the session's connection info.
  final bool Function(String remoteDeviceId, String feature)? featureResolver;

  /// Timings of recent transfers, shown in Diagnostics.
  final TransferStatsLog statsLog = TransferStatsLog();

  final Map<String, TransferTask> _tasks = {};
  final Map<String, Completer<TransferBatchResponsePayload>> _pendingBatches =
      {};
  final Map<String, String> _pendingBatchPeers = {};
  final StreamController<IncomingBatchRequest> _incomingBatchesController =
      StreamController<IncomingBatchRequest>.broadcast();
  final Map<String, StreamSubscription<VayuPacket>> _sessionSubscriptions = {};
  final StreamController<IncomingTransferRequest> _incomingRequestsController =
      StreamController<IncomingTransferRequest>.broadcast();
  StreamSubscription<SecureSession>? _newSessionSubscription;
  bool _isDisposed = false;

  TransferEngineImpl({
    required this.localDeviceId,
    this.secureSessionManager,
    this.sessionResolver,
    ConsentRegistry? consentRegistry,
    this.featureResolver,
  }) : consentRegistry = consentRegistry ?? ConsentRegistry() {
    if (secureSessionManager != null) {
      _newSessionSubscription = secureSessionManager!.secureSessions.listen(
        registerSession,
      );
      for (final session in secureSessionManager!.activeSessions) {
        registerSession(session);
      }
    }
  }

  @override
  Stream<IncomingTransferRequest> get incomingTransferRequests =>
      _incomingRequestsController.stream;

  @override
  List<TransferTask> get activeTransfers => _tasks.values.toList();

  /// Chunk size for BLE links: small, the GATT layer slices it further.
  static const int bleChunkSize = 64 * 1024;

  /// Chunk size for Wi-Fi/LAN links. Larger chunks mean fewer encrypt, read
  /// and ACK round trips per megabyte (each a native bridge call on Android).
  static const int wifiChunkSize = 256 * 1024;

  /// Bytes the sender keeps in flight on Wi-Fi/LAN. Bounded so that, even at
  /// ~1 MB/s, the last chunk in flight is acknowledged well inside the
  /// 10-second chunk timeout.
  static const int wifiInFlightBytes = 4 * 1024 * 1024;

  TransportType? _transportOf(String remoteDeviceId) {
    final session = _resolveSession(remoteDeviceId);
    return session is SecureSessionImpl
        ? session.connectionSession.info.activeTransport
        : null;
  }

  @override
  int chunkSizeFor(String targetDeviceId) {
    final transport = _transportOf(targetDeviceId);
    return transport == null || transport == TransportType.ble
        ? bleChunkSize
        : wifiChunkSize;
  }

  /// Sender window (chunks in flight) for [chunkSize] on this peer's link.
  int _windowFor(String targetDeviceId, int chunkSize) {
    final transport = _transportOf(targetDeviceId);
    if (transport == null || transport == TransportType.ble) return 8;
    return (wifiInFlightBytes ~/ max(1, chunkSize)).clamp(8, 32);
  }

  void _recordStats(TransferStats stats) {
    statsLog.record(stats);
    AppLogger.info('TransferStats', stats.summary());
  }

  @override
  Stream<IncomingBatchRequest> get incomingBatchRequests =>
      _incomingBatchesController.stream;

  @override
  bool supportsBatchOffers(String targetDeviceId) {
    final resolver = featureResolver;
    if (resolver != null) {
      return resolver(targetDeviceId, AppConstants.featureBatchOffer);
    }
    final session = _resolveSession(targetDeviceId);
    return session is SecureSessionImpl &&
        session.connectionSession.info.remoteFeatures.contains(
          AppConstants.featureBatchOffer,
        );
  }

  @override
  Future<void> offerBatch({
    required String targetDeviceId,
    required String batchId,
    required List<BatchManifestEntry> files,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final session = _resolveSession(targetDeviceId);
    if (session == null || !session.isEstablished) {
      throw StateError('No established session with $targetDeviceId');
    }
    registerSession(session);

    final offer = TransferBatchOfferPayload(
      batchId: parseIdTo16Bytes(batchId),
      files: files,
    );
    final key = offer.batchIdHex;
    final completer = Completer<TransferBatchResponsePayload>();
    _pendingBatches[key] = completer;
    _pendingBatchPeers[key] = session.sessionId;

    try {
      await session.sendEncryptedPacket(
        VayuPacket(
          packetType: PacketType.transferBatchOffer,
          packetId: DateTime.now().microsecondsSinceEpoch,
          sourceDeviceId: parseIdTo16Bytes(localDeviceId),
          destinationDeviceId: parseIdTo16Bytes(targetDeviceId),
          payload: offer.toBytes(),
        ),
      );
      final response = await completer.future.timeout(
        timeout,
        onTimeout: () => TransferBatchResponsePayload(
          batchId: offer.batchId,
          accepted: false,
          reason: TransferCancelReason.timeout,
          message: 'No answer from the receiving device',
        ),
      );
      if (!response.accepted) {
        throw TransferBatchDeclinedException(
          response.reason ?? TransferCancelReason.declined,
          response.message.isNotEmpty ? response.message : 'Declined',
        );
      }
    } finally {
      _pendingBatches.remove(key);
      _pendingBatchPeers.remove(key);
    }
  }

  /// Registers and attaches packet listening to a newly established [SecureSession].
  void registerSession(SecureSession session) {
    if (_isDisposed) return;
    if (_sessionSubscriptions.containsKey(session.sessionId)) return;

    AppLogger.info(
      'TransferEngine',
      'Registering secure session ${session.sessionId} for peer ${session.remoteDeviceId}',
    );

    final sub = session.incomingDecryptedPackets.listen(
      (packet) => _handleIncomingPacket(session, packet),
      onError: (e) {
        AppLogger.warning(
          'TransferEngine',
          'Session ${session.sessionId} packet stream error: $e',
        );
      },
      onDone: () {
        _sessionSubscriptions.remove(session.sessionId)?.cancel();
        _handleSessionClosed(session, 'Authenticated session closed');
      },
    );

    _sessionSubscriptions[session.sessionId] = sub;
  }

  void _handleSessionClosed(SecureSession session, String reason) {
    for (final entry in _pendingBatchPeers.entries.toList()) {
      if (entry.value != session.sessionId) continue;
      final completer = _pendingBatches[entry.key];
      if (completer != null && !completer.isCompleted) {
        completer.completeError(TransferConnectionException(entry.key, reason));
      }
    }
    for (final task in _tasks.values.toList()) {
      if (task is OutboundTransferTask &&
          identical(task.secureSession, session)) {
        task.handleSessionClosed(reason);
      } else if (task is InboundTransferTask &&
          identical(task.secureSession, session)) {
        task.handleSessionClosed(reason).ignore();
      }
    }
  }

  /// Resolves an active [SecureSession] for [remoteDeviceId].
  SecureSession? _resolveSession(String remoteDeviceId) {
    if (sessionResolver != null) {
      final s = sessionResolver!(remoteDeviceId);
      if (s != null) return s;
    }
    if (secureSessionManager != null) {
      return secureSessionManager!.getSessionForPeer(remoteDeviceId);
    }
    return null;
  }

  @override
  Future<TransferTask> sendPayload({
    required String targetDeviceId,
    required PayloadSource source,
    required TransferMetadata metadata,
  }) async {
    if (_isDisposed) {
      throw StateError('Cannot initiate transfer on disposed TransferEngine');
    }

    final session = _resolveSession(targetDeviceId);
    if (session == null || !session.isEstablished) {
      throw StateError(
        'No active, established SecureSession found for peer $targetDeviceId',
      );
    }

    // Ensure session is registered for packet listening
    registerSession(session);

    final task = OutboundTransferTask(
      transferId: metadata.transferId,
      localDeviceId: localDeviceId,
      remoteDeviceId: targetDeviceId,
      secureSession: session,
      source: source,
      metadata: metadata,
      onStats: _recordStats,
      windowSize: _windowFor(targetDeviceId, metadata.chunkSize),
    );

    _tasks[metadata.transferId] = task;

    task.done.whenComplete(() {
      AppLogger.info(
        'TransferEngine',
        'Outbound transfer ${metadata.transferId} finalized with status: ${task.status}',
      );
      _tasks.remove(metadata.transferId);
    }).ignore();

    await task.start();
    return task;
  }

  Future<void> _handleIncomingPacket(
    SecureSession session,
    VayuPacket packet,
  ) async {
    if (_isDisposed) return;

    switch (packet.packetType) {
      case PacketType.transferMetadata:
        await _handleMetadataPacket(session, packet);
        break;

      case PacketType.transferChunk:
        _handleChunkPacket(packet);
        break;

      case PacketType.transferAck:
        _handleAckPacket(packet);
        break;

      case PacketType.transferNack:
        _handleNackPacket(packet);
        break;

      case PacketType.transferCancel:
        await _handleCancelPacket(packet);
        break;

      case PacketType.transferBatchOffer:
        _handleBatchOfferPacket(session, packet);
        break;

      case PacketType.transferBatchResponse:
        _handleBatchResponsePacket(session, packet);
        break;

      default:
        // Ignore non-transfer packet types
        break;
    }
  }

  Future<void> _handleMetadataPacket(
    SecureSession session,
    VayuPacket packet,
  ) async {
    try {
      final metaPayload = TransferMetadataPayload.fromBytes(packet.payload);
      final transferIdHex = metaPayload.transferIdHex;

      AppLogger.info(
        'TransferEngine',
        'Received incoming transfer offer $transferIdHex for file: ${metaPayload.fileName} (${metaPayload.totalBytes} bytes)',
      );

      final metadata = TransferMetadata(
        transferId: transferIdHex,
        fileName: metaPayload.fileName,
        totalBytes: metaPayload.totalBytes,
        chunkSize: metaPayload.chunkSize,
        sha256Checksum: metaPayload.sha256Hex,
        mimeType: metaPayload.mimeType,
        payloadType: metaPayload.payloadType,
        extraMetadata: metaPayload.extraMetadata,
      );

      // A batch tag only names a batch. The file is pre-approved solely when
      // this device's own consent record for that sender and batch covers it.
      final marker = BatchFileMarker.tryDecode(metaPayload.extraMetadata);
      final authorized =
          marker != null &&
          consentRegistry.claim(
            senderDeviceId: session.remoteDeviceId,
            batchId: marker.batchIdHex,
            index: marker.index,
            fileName: metadata.fileName,
            sizeBytes: metadata.totalBytes,
            mimeType: metadata.mimeType,
          );

      Future<TransferTask> accept(PayloadDestination destination) async {
        final TransferTask task;
        try {
          task = await _acceptTransfer(
            session,
            metaPayload,
            metadata,
            destination,
          );
        } catch (_) {
          if (authorized) _settleClaim(session, marker, completed: false);
          rethrow;
        }
        if (authorized) {
          task.done.then(
            (_) => _settleClaim(session, marker, completed: true),
            onError: (_) => _settleClaim(session, marker, completed: false),
          );
        }
        return task;
      }

      final request = IncomingTransferRequest(
        transferId: transferIdHex,
        senderDeviceId: session.remoteDeviceId,
        metadata: metadata,
        authorizedBatchId: authorized ? marker.batchIdHex : null,
        onAccept: (savePath) => accept(
          FilePayloadDestination(
            targetFilePath: savePath,
            totalBytes: metadata.totalBytes,
          ),
        ),
        onAcceptCustom: accept,
        onDecline: ([reason]) => _rejectOffer(
          session,
          metaPayload,
          TransferCancelReason.declined,
          reason ?? 'Declined by recipient',
        ),
        onReject: (code, message) {
          if (authorized) _settleClaim(session, marker, completed: false);
          return _rejectOffer(session, metaPayload, code, message);
        },
      );

      _incomingRequestsController.add(request);
    } catch (e, stack) {
      AppLogger.error(
        'TransferEngine',
        'Failed to parse incoming TransferMetadata packet: $e',
        stackTrace: stack,
      );
    }
  }

  void _settleClaim(
    SecureSession session,
    BatchFileMarker marker, {
    required bool completed,
  }) {
    consentRegistry.settle(
      senderDeviceId: session.remoteDeviceId,
      batchId: marker.batchIdHex,
      index: marker.index,
      completed: completed,
    );
  }

  void _handleBatchOfferPacket(SecureSession session, VayuPacket packet) {
    final TransferBatchOfferPayload offer;
    try {
      offer = TransferBatchOfferPayload.fromBytes(packet.payload);
    } catch (e) {
      AppLogger.warning('TransferEngine', 'Ignoring malformed batch offer: $e');
      return;
    }
    AppLogger.info(
      'TransferEngine',
      'Received batch offer ${offer.batchIdHex}: ${offer.files.length} files, ${offer.totalBytes} bytes',
    );

    var answered = false;
    Future<void> respond(
      bool accepted, [
      TransferCancelReason? reason,
      String message = '',
    ]) async {
      if (answered) return;
      answered = true;
      if (accepted) {
        consentRegistry.grant(
          senderDeviceId: session.remoteDeviceId,
          batchId: offer.batchIdHex,
          entries: offer.files,
        );
      }
      final response = TransferBatchResponsePayload(
        batchId: offer.batchId,
        accepted: accepted,
        reason: reason,
        message: message,
      );
      await session.sendEncryptedPacket(
        VayuPacket(
          packetType: PacketType.transferBatchResponse,
          packetId: DateTime.now().microsecondsSinceEpoch,
          sourceDeviceId: parseIdTo16Bytes(localDeviceId),
          destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
          payload: response.toBytes(),
        ),
      );
    }

    _incomingBatchesController.add(
      IncomingBatchRequest(
        batchId: offer.batchIdHex,
        senderDeviceId: session.remoteDeviceId,
        files: offer.files,
        onAccept: () => respond(true),
        onReject: (code, message) => respond(false, code, message),
      ),
    );
  }

  void _handleBatchResponsePacket(SecureSession session, VayuPacket packet) {
    try {
      final response = TransferBatchResponsePayload.fromBytes(packet.payload);
      final key = response.batchIdHex;
      // Only the session the offer went out on may answer it.
      if (_pendingBatchPeers[key] != session.sessionId) return;
      final completer = _pendingBatches[key];
      if (completer != null && !completer.isCompleted) {
        completer.complete(response);
      }
    } catch (e) {
      AppLogger.warning('TransferEngine', 'Ignoring malformed batch reply: $e');
    }
  }

  Future<void> _rejectOffer(
    SecureSession session,
    TransferMetadataPayload metaPayload,
    TransferCancelReason code,
    String message,
  ) async {
    final cancel = TransferCancelPayload(
      transferId: metaPayload.transferId,
      reason: code,
      message: message,
    );
    final cancelPacket = VayuPacket(
      packetType: PacketType.transferCancel,
      packetId: DateTime.now().microsecondsSinceEpoch,
      sourceDeviceId: parseIdTo16Bytes(localDeviceId),
      destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
      payload: cancel.toBytes(),
    );
    await session.sendEncryptedPacket(cancelPacket);
  }

  Future<TransferTask> _acceptTransfer(
    SecureSession session,
    TransferMetadataPayload metaPayload,
    TransferMetadata metadata,
    PayloadDestination destination,
  ) async {
    final inboundTask = InboundTransferTask(
      transferId: metadata.transferId,
      localDeviceId: localDeviceId,
      remoteDeviceId: session.remoteDeviceId,
      secureSession: session,
      destination: destination,
      metadata: metadata,
      onStats: _recordStats,
    );

    _tasks[metadata.transferId] = inboundTask;

    inboundTask.done.whenComplete(() {
      AppLogger.info(
        'TransferEngine',
        'Inbound transfer ${metadata.transferId} finalized with status: ${inboundTask.status}',
      );
      _tasks.remove(metadata.transferId);
    }).ignore();

    // Send initial ACK (offer accepted)
    final ack = TransferAckPayload(
      transferId: metaPayload.transferId,
      ackType: TransferAckType.offerAccepted,
      highestContiguousChunkIndex: TransferAckPayload.noneAcked,
      bytesReceived: 0,
      selectiveBitmapOffset: 0,
      selectiveBitmap: Uint8List(0),
    );

    final ackPacket = VayuPacket(
      packetType: PacketType.transferAck,
      packetId: DateTime.now().microsecondsSinceEpoch,
      sourceDeviceId: parseIdTo16Bytes(localDeviceId),
      destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
      payload: ack.toBytes(),
    );

    try {
      await session.sendEncryptedPacket(ackPacket);
    } catch (e) {
      _tasks.remove(metadata.transferId);
      await inboundTask.handleSessionClosed('Unable to accept transfer: $e');
      rethrow;
    }

    if (metadata.chunkCount == 0) {
      await inboundTask.verifyIfEmpty();
    }

    return inboundTask;
  }

  void _handleChunkPacket(VayuPacket packet) {
    try {
      if (packet.payload.length < 16) return;
      final tIdBytes = packet.payload.sublist(0, 16);
      final tIdHex = tIdBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final task = _tasks[tIdHex];
      if (task is InboundTransferTask) {
        final chunk = TransferChunkPayload.fromBytes(packet.payload);
        task.handleChunk(chunk);
      }
    } catch (e) {
      AppLogger.warning('TransferEngine', 'Failed to handle chunk packet: $e');
    }
  }

  void _handleAckPacket(VayuPacket packet) {
    try {
      if (packet.payload.length < 16) return;
      final tIdBytes = packet.payload.sublist(0, 16);
      final tIdHex = tIdBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final task = _tasks[tIdHex];
      if (task is OutboundTransferTask) {
        final ack = TransferAckPayload.fromBytes(packet.payload);
        task.handleAck(ack);
      }
    } catch (e) {
      AppLogger.warning('TransferEngine', 'Failed to handle ACK packet: $e');
    }
  }

  void _handleNackPacket(VayuPacket packet) {
    try {
      if (packet.payload.length < 16) return;
      final tIdBytes = packet.payload.sublist(0, 16);
      final tIdHex = tIdBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final task = _tasks[tIdHex];
      if (task is OutboundTransferTask) {
        final nack = TransferNackPayload.fromBytes(packet.payload);
        task.handleNack(nack);
      }
    } catch (e) {
      AppLogger.warning('TransferEngine', 'Failed to handle NACK packet: $e');
    }
  }

  Future<void> _handleCancelPacket(VayuPacket packet) async {
    try {
      if (packet.payload.length < 16) return;
      final tIdBytes = packet.payload.sublist(0, 16);
      final tIdHex = tIdBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final task = _tasks[tIdHex];
      final cancel = TransferCancelPayload.fromBytes(packet.payload);

      if (task is OutboundTransferTask) {
        task.handleCancel(cancel);
      } else if (task is InboundTransferTask) {
        await task.handleCancel(cancel);
      }
    } catch (e) {
      AppLogger.warning('TransferEngine', 'Failed to handle Cancel packet: $e');
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    await _newSessionSubscription?.cancel();
    _newSessionSubscription = null;

    for (final sub in _sessionSubscriptions.values.toList()) {
      await sub.cancel();
    }
    _sessionSubscriptions.clear();

    for (final task in _tasks.values.toList()) {
      await task.cancel('TransferEngine disposed');
    }
    _tasks.clear();

    if (!_incomingRequestsController.isClosed) {
      await _incomingRequestsController.close();
    }
    if (!_incomingBatchesController.isClosed) {
      await _incomingBatchesController.close();
    }
  }
}
