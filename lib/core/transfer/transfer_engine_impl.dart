import 'dart:async';
import 'dart:io';
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
import 'package:vayu/core/transfer/resumable_transfers.dart';
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
  // The engine is the one subscriber of every session's packets (a later
  // subscriber could miss the first ones), so it hands Wi-Fi Direct upgrade
  // messages on to the connection layer.
  final StreamController<({SecureSession session, VayuPacket packet})>
  _linkUpgradePackets = StreamController.broadcast();

  /// Link upgrade requests and answers (packets 0x40/0x41) of any session.
  Stream<({SecureSession session, VayuPacket packet})> get linkUpgradePackets =>
      _linkUpgradePackets.stream;

  final StreamController<({SecureSession session, VayuPacket packet})>
  _chatPackets = StreamController.broadcast();

  /// Chat messages and receipts (packets 0x20/0x21) of any session.
  Stream<({SecureSession session, VayuPacket packet})> get chatPackets =>
      _chatPackets.stream;

  final StreamController<({SecureSession session, VayuPacket packet})>
  _hostPackets = StreamController.broadcast();

  /// Host & Client packets (0x50-0x54) of any session.
  Stream<({SecureSession session, VayuPacket packet})> get hostPackets =>
      _hostPackets.stream;

  final StreamController<({SecureSession session, VayuPacket packet})>
  _meshPackets = StreamController.broadcast();

  /// Mesh relay packets (0x60-0x65) of any session.
  Stream<({SecureSession session, VayuPacket packet})> get meshPackets =>
      _meshPackets.stream;

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
    ResumableTransfers? resumable,
  }) : consentRegistry = consentRegistry ?? ConsentRegistry(),
       resumable = resumable ?? ResumableTransfers() {
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
  /// and ACK round trips per megabyte (each a native bridge call on Android);
  /// 1 MiB measured fastest in the loopback benchmark. Receivers of any
  /// version accept it (the size travels in the metadata).
  static const int wifiChunkSize = 1024 * 1024;

  /// Bytes the sender keeps in flight on Wi-Fi/LAN. Bounded so that, even at
  /// ~1 MB/s, the last chunk in flight is acknowledged inside the 10-second
  /// chunk timeout.
  static const int wifiInFlightBytes = 6 * 1024 * 1024;

  TransportType? _transportOf(String remoteDeviceId) {
    final session = _resolveSession(remoteDeviceId);
    return session is SecureSessionImpl
        ? session.connectionSession.info.activeTransport
        : null;
  }

  /// Link name for speed diagnostics. TCP over a Wi-Fi Direct group is told
  /// apart by Android's fixed group subnet.
  String? _linkOf(String remoteDeviceId) {
    final session = _resolveSession(remoteDeviceId);
    if (session is! SecureSessionImpl) return null;
    final info = session.connectionSession.info;
    if (info.activeTransport == TransportType.lan &&
        (info.remoteAddress?.startsWith('192.168.49.') ?? false)) {
      return 'wifiDirect';
    }
    return info.activeTransport.name;
  }

  @override
  int chunkSizeFor(String targetDeviceId) {
    final transport = _transportOf(targetDeviceId);
    // A relayed link may cross Bluetooth hops: sized like Bluetooth.
    return transport == null ||
            transport == TransportType.ble ||
            transport == TransportType.relay
        ? bleChunkSize
        : wifiChunkSize;
  }

  /// Sender window (chunks in flight) for [chunkSize] on this peer's link.
  int _windowFor(String targetDeviceId, int chunkSize) {
    final transport = _transportOf(targetDeviceId);
    if (transport == null ||
        transport == TransportType.ble ||
        transport == TransportType.relay) {
      return 8;
    }
    return (wifiInFlightBytes ~/ max(1, chunkSize)).clamp(4, 32);
  }

  void _recordStats(TransferStats stats, String remoteDeviceId) {
    stats = stats.withLink(_linkOf(remoteDeviceId));
    statsLog.record(stats);
    AppLogger.info('TransferStats', stats.summary());
  }

  @override
  Stream<IncomingBatchRequest> get incomingBatchRequests =>
      _incomingBatchesController.stream;

  @override
  bool supportsBatchOffers(String targetDeviceId) =>
      _peerSupports(targetDeviceId, AppConstants.featureBatchOffer);

  @override
  bool supportsLateHash(String targetDeviceId) =>
      _peerSupports(targetDeviceId, AppConstants.featureLateHash);

  bool _peerSupports(String targetDeviceId, String feature) {
    final resolver = featureResolver;
    if (resolver != null) return resolver(targetDeviceId, feature);
    final session = _resolveSession(targetDeviceId);
    return session is SecureSessionImpl &&
        session.connectionSession.info.remoteFeatures.contains(feature);
  }

  @override
  Future<void> offerBatch({
    required String targetDeviceId,
    required String batchId,
    required List<BatchManifestEntry> files,
    Duration timeout = const Duration(minutes: 5),
    String? receiveProof,
  }) async {
    final session = _resolveSession(targetDeviceId);
    if (session == null || !session.isEstablished) {
      throw StateError('No established session with $targetDeviceId');
    }
    registerSession(session);

    final offer = TransferBatchOfferPayload(
      batchId: parseIdTo16Bytes(batchId),
      files: files,
      receiveProof: receiveProof,
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
    Future<String>? lateSha256,
  }) async {
    if (_isDisposed) {
      throw StateError('Cannot initiate transfer on disposed TransferEngine');
    }
    if ((lateSha256 != null) != metadata.hashDeferred) {
      throw ArgumentError(
        'A late hash needs the deferred placeholder in the metadata, and the reverse',
      );
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
      onStats: (stats) => _recordStats(stats, targetDeviceId),
      windowSize: _windowFor(targetDeviceId, metadata.chunkSize),
      lateDigest: lateSha256,
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

      case PacketType.transferDigest:
        _handleDigestPacket(session, packet);
        break;

      case PacketType.hostCatalogRequest:
      case PacketType.hostCatalog:
      case PacketType.hostDownloadRequest:
      case PacketType.hostDownloadResponse:
      case PacketType.hostEnded:
        if (!_hostPackets.isClosed) {
          _hostPackets.add((session: session, packet: packet));
        }
        break;

      case PacketType.chatMessage:
      case PacketType.chatDeliveryAck:
      case PacketType.chatFileOffer:
      case PacketType.chatFileAnswer:
        if (!_chatPackets.isClosed) {
          _chatPackets.add((session: session, packet: packet));
        }
        break;

      case PacketType.relayOpen:
      case PacketType.relayOpened:
      case PacketType.relayData:
      case PacketType.relayClose:
      case PacketType.reachQuery:
      case PacketType.reachAnswer:
        if (!_meshPackets.isClosed) {
          _meshPackets.add((session: session, packet: packet));
        }
        break;

      case PacketType.linkUpgradeRequest:
      case PacketType.linkUpgradeResponse:
        if (!_linkUpgradePackets.isClosed) {
          _linkUpgradePackets.add((session: session, packet: packet));
        }
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
        onAccept: (savePath) =>
            _acceptToFile(session, metadata, savePath, accept),
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
        receiveProof: offer.receiveProof,
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

  /// Accepts into [savePath]; continues an interrupted copy of the same file
  /// from this sender when one was kept.
  Future<TransferTask> _acceptToFile(
    SecureSession session,
    TransferMetadata metadata,
    String savePath,
    Future<TransferTask> Function(PayloadDestination destination) accept,
  ) {
    final partial = metadata.hashDeferred
        ? resumable.take(_resumeKey(session, metadata))
        // A known hash may continue a copy started under a late hash.
        : resumable.take(_resumeKey(session, metadata)) ??
              resumable.take(_resumeKeyByName(session, metadata));
    var resumeBytes = 0;
    if (partial != null) {
      // Continue under the interrupted copy's own name when it is still
      // free, giving back the fresh reservation made for this offer.
      const suffix = FilePayloadDestination.stagingSuffix;
      final original = partial.stagingPath.endsWith(suffix)
          ? partial.stagingPath.substring(
              0,
              partial.stagingPath.length - suffix.length,
            )
          : null;
      if (original != null &&
          original != savePath &&
          File(original).parent.path == File(savePath).parent.path &&
          !File(original).existsSync()) {
        try {
          final reserved = File('$savePath$suffix');
          if (reserved.existsSync() && reserved.lengthSync() == 0) {
            reserved.deleteSync();
          }
          savePath = original;
        } catch (_) {}
      }
      final staging = '$savePath$suffix';
      try {
        if (partial.stagingPath != staging) {
          File(partial.stagingPath).renameSync(staging);
        }
        resumeBytes = partial.contiguousBytes;
        _resumeChunks[metadata.transferId] = partial.contiguousChunks;
        AppLogger.info(
          'TransferEngine',
          'Resuming ${metadata.fileName} from byte $resumeBytes',
        );
      } catch (e) {
        AppLogger.warning('TransferEngine', 'Could not resume, restarting: $e');
      }
    }
    return accept(
      FilePayloadDestination(
        targetFilePath: savePath,
        totalBytes: metadata.totalBytes,
        resumeFromBytes: resumeBytes,
      ),
    );
  }

  static String _resumeKey(SecureSession session, TransferMetadata metadata) =>
      metadata.hashDeferred
      ? _resumeKeyByName(session, metadata)
      : ResumableTransfers.keyFor(
          senderDeviceId: session.remoteDeviceId,
          sha256: metadata.sha256Checksum,
          totalBytes: metadata.totalBytes,
          chunkSize: metadata.chunkSize,
        );

  static String _resumeKeyByName(
    SecureSession session,
    TransferMetadata metadata,
  ) => ResumableTransfers.keyForName(
    senderDeviceId: session.remoteDeviceId,
    fileName: metadata.fileName,
    totalBytes: metadata.totalBytes,
    chunkSize: metadata.chunkSize,
  );

  /// Chunks already on disk for transfers being resumed, by transfer ID.
  final Map<String, int> _resumeChunks = {};

  /// Interrupted receives kept for a resume (see [ResumableTransfers]).
  final ResumableTransfers resumable;

  /// Offers the sender cancelled before this side answered them.
  final Set<String> _cancelledOffers = <String>{};

  Future<TransferTask> _acceptTransfer(
    SecureSession session,
    TransferMetadataPayload metaPayload,
    TransferMetadata metadata,
    PayloadDestination destination,
  ) async {
    if (_cancelledOffers.remove(metadata.transferId)) {
      await destination.abortAndCleanup();
      throw TransferCancelledException(
        metadata.transferId,
        'The sender stopped sending this file',
      );
    }
    final resumeChunks = _resumeChunks.remove(metadata.transferId) ?? 0;
    final resumeBytes = min(
      resumeChunks * metadata.chunkSize,
      metadata.totalBytes,
    );
    final resumeKey = _resumeKey(session, metadata);
    final inboundTask = InboundTransferTask(
      transferId: metadata.transferId,
      localDeviceId: localDeviceId,
      remoteDeviceId: session.remoteDeviceId,
      secureSession: session,
      destination: destination,
      metadata: metadata,
      onStats: (stats) => _recordStats(stats, session.remoteDeviceId),
      initialContiguousChunkIndex: resumeChunks - 1,
      initialBytesReceived: resumeBytes,
      onInterrupted: _isDisposed
          ? null
          : (partial) => resumable.keep(resumeKey, partial),
    );

    _tasks[metadata.transferId] = inboundTask;

    inboundTask.done.whenComplete(() {
      AppLogger.info(
        'TransferEngine',
        'Inbound transfer ${metadata.transferId} finalized with status: ${inboundTask.status}',
      );
      _tasks.remove(metadata.transferId);
    }).ignore();

    // Initial ACK: accepted, or accepted from a checkpoint when part of the
    // file is already here (every sender build continues from it).
    final ack = TransferAckPayload(
      transferId: metaPayload.transferId,
      ackType: resumeChunks > 0
          ? TransferAckType.resumeCheckpoint
          : TransferAckType.offerAccepted,
      highestContiguousChunkIndex: resumeChunks > 0
          ? resumeChunks - 1
          : TransferAckPayload.noneAcked,
      bytesReceived: resumeBytes,
      selectiveBitmapOffset: resumeChunks,
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

  void _handleDigestPacket(SecureSession session, VayuPacket packet) {
    try {
      final digest = TransferDigestPayload.fromBytes(packet.payload);
      final task = _tasks[digest.transferIdHex];
      // Only the sender of that file may supply its hash.
      if (task is InboundTransferTask &&
          identical(task.secureSession, session)) {
        task.handleDigest(digest);
      }
    } catch (e) {
      AppLogger.warning('TransferEngine', 'Failed to handle digest packet: $e');
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
      } else if (task == null) {
        // Cancelled while its offer still awaits an answer here: accepting it
        // later would wait forever for chunks that never come.
        _cancelledOffers.add(tIdHex);
        if (_cancelledOffers.length > 64) {
          _cancelledOffers.remove(_cancelledOffers.first);
        }
      }
    } catch (e) {
      AppLogger.warning('TransferEngine', 'Failed to handle Cancel packet: $e');
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    resumable.dispose();

    await _newSessionSubscription?.cancel();
    _newSessionSubscription = null;

    for (final sub in _sessionSubscriptions.values.toList()) {
      await sub.cancel();
    }
    _sessionSubscriptions.clear();
    await _linkUpgradePackets.close();
    await _meshPackets.close();
    await _chatPackets.close();
    await _hostPackets.close();

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
