import 'dart:async';
import 'dart:typed_data';

import 'package:silosend_datasharing_app/core/contracts/security_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transfer_contract.dart';
import 'package:silosend_datasharing_app/core/logging/app_logger.dart';
import 'package:silosend_datasharing_app/core/security/secure_session_manager.dart';
import 'package:silosend_datasharing_app/core/transfer/transfer_task_impl.dart';
import 'package:silosend_datasharing_app/domain/models/transfer_models.dart';
import 'package:silosend_datasharing_app/domain/protocol/packet_type.dart';
import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';
import 'package:silosend_datasharing_app/domain/transfer/payload_destination.dart';
import 'package:silosend_datasharing_app/domain/transfer/transfer_packet_payloads.dart';

/// Concrete implementation of [TransferEngine] managing active, multiplexed file
/// and data transfers end-to-end over authenticated [SecureSession] instances.
class TransferEngineImpl implements TransferEngine {
  final String localDeviceId;
  final SecureSessionManager? secureSessionManager;
  final SecureSession? Function(String remoteDeviceId)? sessionResolver;

  final Map<String, TransferTask> _tasks = {};
  final Map<String, StreamSubscription<SiloSendPacket>> _sessionSubscriptions =
      {};
  final StreamController<IncomingTransferRequest> _incomingRequestsController =
      StreamController<IncomingTransferRequest>.broadcast();
  StreamSubscription<SecureSession>? _newSessionSubscription;
  bool _isDisposed = false;

  TransferEngineImpl({
    required this.localDeviceId,
    this.secureSessionManager,
    this.sessionResolver,
  }) {
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
    SiloSendPacket packet,
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

      default:
        // Ignore non-transfer packet types
        break;
    }
  }

  Future<void> _handleMetadataPacket(
    SecureSession session,
    SiloSendPacket packet,
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

      final request = IncomingTransferRequest(
        transferId: transferIdHex,
        senderDeviceId: session.remoteDeviceId,
        metadata: metadata,
        onAccept: (savePath) async {
          final destination = FilePayloadDestination(
            targetFilePath: savePath,
            totalBytes: metadata.totalBytes,
          );
          return _acceptTransfer(session, metaPayload, metadata, destination);
        },
        onAcceptCustom: (destination) async {
          return _acceptTransfer(session, metaPayload, metadata, destination);
        },
        onDecline: ([reason]) async {
          final cancel = TransferCancelPayload(
            transferId: metaPayload.transferId,
            reason: TransferCancelReason.declined,
            message: reason ?? 'Declined by recipient',
          );
          final cancelPacket = SiloSendPacket(
            packetType: PacketType.transferCancel,
            packetId: DateTime.now().microsecondsSinceEpoch,
            sourceDeviceId: parseIdTo16Bytes(localDeviceId),
            destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
            payload: cancel.toBytes(),
          );
          await session.sendEncryptedPacket(cancelPacket);
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

    final ackPacket = SiloSendPacket(
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

  void _handleChunkPacket(SiloSendPacket packet) {
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

  void _handleAckPacket(SiloSendPacket packet) {
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

  void _handleNackPacket(SiloSendPacket packet) {
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

  Future<void> _handleCancelPacket(SiloSendPacket packet) async {
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
  }
}
