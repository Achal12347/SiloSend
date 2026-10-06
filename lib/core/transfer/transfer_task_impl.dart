import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

/// Helper to parse hex/UUID strings into 16-byte raw byte identifiers.
Uint8List parseIdTo16Bytes(String id) {
  final clean = id.replaceAll('-', '').toLowerCase();
  if (clean.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(clean)) {
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
  final hash = crypto.sha256.convert(utf8.encode(id)).bytes;
  return Uint8List.fromList(hash.sublist(0, 16));
}

/// Helper to parse a 64-char SHA256 hex string to 32 bytes.
Uint8List parseSha256HexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
  if (clean.length == 64) {
    final bytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
  final digest = crypto.sha256.convert(utf8.encode(hex)).bytes;
  return Uint8List.fromList(digest);
}

/// Concrete implementation of an active outbound (sender) transfer task.
///
/// Features:
/// - Pipelined sliding window of unacknowledged chunks (default W=8).
/// - Dynamic cumulative and selective acknowledgment handling (SACK).
/// - Per-chunk timer with configurable retry threshold (default 3 retries, 5s timeout).
/// - Fast retransmit upon receiving CRC NACKs.
/// - Speed calculation and ETA estimation.
/// - Cooperative pause, resume, and cancellation.
class OutboundTransferTask implements TransferTask {
  @override
  final String transferId;

  final String localDeviceId;

  @override
  final String remoteDeviceId;

  final SecureSession secureSession;
  final PayloadSource source;

  @override
  final TransferMetadata metadata;

  final int windowSize;
  final Duration chunkTimeout;
  final int maxRetries;

  TransferStatus _status = TransferStatus.idle;
  final StreamController<TransferProgress> _progressController =
      StreamController<TransferProgress>.broadcast();
  final Completer<void> _doneCompleter = Completer<void>();

  late final Uint8List _transferIdBytes;
  late final Uint8List _localIdBytes;
  late final Uint8List _remoteIdBytes;

  int _highestContiguousAcked = -1;
  final Set<int> _ackedChunks = {};
  final Map<int, int> _chunkRetryCounts = {};
  final Map<int, Timer> _chunkTimers = {};
  final Map<int, TransferChunkPayload> _inFlightChunks = {};
  int _nextChunkToSend = 0;
  int _bytesAcked = 0;

  bool _isPaused = false;
  Completer<void>? _pauseCompleter;
  bool _isDisposed = false;

  DateTime? _transferStartTime;
  int _lastBytesSample = 0;
  DateTime _lastSampleTime = DateTime.now();
  double _currentSpeed = 0.0;

  OutboundTransferTask({
    required this.transferId,
    required this.localDeviceId,
    required this.remoteDeviceId,
    required this.secureSession,
    required this.source,
    required this.metadata,
    this.windowSize = 8,
    this.chunkTimeout = const Duration(seconds: 5),
    this.maxRetries = 3,
  }) {
    _transferIdBytes = parseIdTo16Bytes(transferId);
    _localIdBytes = parseIdTo16Bytes(localDeviceId);
    _remoteIdBytes = parseIdTo16Bytes(remoteDeviceId);
    _doneCompleter.future.ignore();
  }

  @override
  TransferStatus get status => _status;

  @override
  Stream<TransferProgress> get progressStream => _progressController.stream;

  /// Future completing when the transfer completes successfully or with error.
  @override
  Future<void> get done => _doneCompleter.future;

  /// Begins the outbound transfer pipeline.
  Future<void> start() async {
    if (_status != TransferStatus.idle) return;
    _status = TransferStatus.transferring;
    _transferStartTime = DateTime.now();
    _lastSampleTime = DateTime.now();

    _emitProgress();

    AppLogger.info(
      'OutboundTransferTask',
      'Starting outbound transfer $transferId (${metadata.fileName}, ${metadata.totalBytes} bytes, ${metadata.chunkCount} chunks)',
    );

    // 1. Send TransferMetadataPayload
    final hashBytes = parseSha256HexToBytes(metadata.sha256Checksum);
    final metaPayload = TransferMetadataPayload(
      transferId: _transferIdBytes,
      payloadType: metadata.payloadType,
      totalBytes: metadata.totalBytes,
      chunkSize: metadata.chunkSize,
      chunkCount: metadata.chunkCount,
      sha256Hash: hashBytes,
      fileName: metadata.fileName,
      mimeType: metadata.mimeType,
      extraMetadata: metadata.extraMetadata,
    );

    final packet = VayuPacket(
      packetType: PacketType.transferMetadata,
      packetId: DateTime.now().microsecondsSinceEpoch,
      sourceDeviceId: _localIdBytes,
      destinationDeviceId: _remoteIdBytes,
      payload: metaPayload.toBytes(),
    );

    try {
      await secureSession.sendEncryptedPacket(packet);
    } catch (e) {
      handleSessionClosed('Unable to start transfer: $e');
      rethrow;
    }

    if (metadata.chunkCount == 0) {
      // Empty payload: Wait for ACK from receiver
      return;
    }

    // Window pump will be activated upon initial offerAccepted / resumeCheckpoint ACK
    // or we can pre-prime window if immediate sending is desired. In Vayu wire protocol,
    // receiver must accept the offer before sending chunks.
  }

  /// Pushes unacknowledged chunks within the sliding window.
  Future<void> _pumpWindow() async {
    if (_isPaused || _status != TransferStatus.transferring || _isDisposed) {
      return;
    }

    while (_inFlightChunks.length < windowSize &&
        _nextChunkToSend < metadata.chunkCount) {
      final chunkIdx = _nextChunkToSend;

      if (_ackedChunks.contains(chunkIdx) ||
          (_highestContiguousAcked != -1 &&
              chunkIdx <= _highestContiguousAcked)) {
        _nextChunkToSend++;
        continue;
      }

      _nextChunkToSend++;
      await _sendChunk(chunkIdx);
    }
  }

  Future<void> _sendChunk(int chunkIdx) async {
    if (_status != TransferStatus.transferring || _isDisposed) return;

    final offset = chunkIdx * metadata.chunkSize;
    final remaining = metadata.totalBytes - offset;
    final length = remaining > metadata.chunkSize
        ? metadata.chunkSize
        : remaining;

    try {
      final chunkBytes = await source.readChunk(offset, length);
      final chunkPayload = TransferChunkPayload.create(
        transferId: _transferIdBytes,
        chunkIndex: chunkIdx,
        chunkOffset: offset,
        chunkData: chunkBytes,
      );

      _inFlightChunks[chunkIdx] = chunkPayload;

      final packet = VayuPacket(
        packetType: PacketType.transferChunk,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: _localIdBytes,
        destinationDeviceId: _remoteIdBytes,
        payload: chunkPayload.toBytes(),
      );

      await secureSession.sendEncryptedPacket(packet);
      _startChunkTimer(chunkIdx);
    } catch (e) {
      AppLogger.error(
        'OutboundTransferTask',
        'Failed to read/send chunk $chunkIdx',
        error: e,
      );
      _failWithStorage('Failed to read chunk $chunkIdx: $e');
    }
  }

  void _startChunkTimer(int chunkIdx) {
    _chunkTimers[chunkIdx]?.cancel();
    _chunkTimers[chunkIdx] = Timer(
      chunkTimeout,
      () => _handleChunkTimeout(chunkIdx),
    );
  }

  Future<void> _handleChunkTimeout(int chunkIdx) async {
    if (_status != TransferStatus.transferring || _isDisposed) return;
    if (_ackedChunks.contains(chunkIdx) ||
        (_highestContiguousAcked != -1 &&
            chunkIdx <= _highestContiguousAcked)) {
      return;
    }

    final retries = (_chunkRetryCounts[chunkIdx] ?? 0) + 1;
    if (retries > maxRetries) {
      AppLogger.warning(
        'OutboundTransferTask',
        'Chunk $chunkIdx timed out after $maxRetries retries. Aborting transfer.',
      );
      _failWithTimeout(chunkIdx, retries);
      return;
    }

    _chunkRetryCounts[chunkIdx] = retries;
    AppLogger.info(
      'OutboundTransferTask',
      'Chunk $chunkIdx timed out (retry $retries/$maxRetries). Resending...',
    );

    // Resend chunk
    final payload = _inFlightChunks[chunkIdx];
    if (payload != null) {
      final packet = VayuPacket(
        packetType: PacketType.transferChunk,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: _localIdBytes,
        destinationDeviceId: _remoteIdBytes,
        payload: payload.toBytes(),
      );
      try {
        await secureSession.sendEncryptedPacket(packet);
        _startChunkTimer(chunkIdx);
      } catch (e) {
        AppLogger.warning(
          'OutboundTransferTask',
          'Error resending chunk $chunkIdx: $e',
        );
      }
    }
  }

  /// Handles incoming ACK packets routed to this transfer.
  void handleAck(TransferAckPayload ack) {
    if (_status != TransferStatus.transferring &&
        _status != TransferStatus.idle) {
      return;
    }

    if (ack.ackType == TransferAckType.offerAccepted ||
        ack.ackType == TransferAckType.resumeCheckpoint) {
      _status = TransferStatus.transferring;

      if (ack.highestContiguousChunkIndex != TransferAckPayload.noneAcked) {
        _highestContiguousAcked = ack.highestContiguousChunkIndex;
        _bytesAcked = ack.bytesReceived;
        _nextChunkToSend = max(
          _nextChunkToSend,
          ack.highestContiguousChunkIndex + 1,
        );

        for (int i = 0; i <= _highestContiguousAcked; i++) {
          _ackedChunks.add(i);
          _inFlightChunks.remove(i);
          _chunkTimers.remove(i)?.cancel();
        }
      }

      _emitProgress();

      if (metadata.chunkCount == 0) {
        _finishSuccess();
        return;
      }

      _pumpWindow();
      return;
    }

    if (ack.ackType == TransferAckType.chunkReceived ||
        ack.ackType == TransferAckType.transferCompleted) {
      // 1. Process Cumulative ACK
      if (ack.highestContiguousChunkIndex != TransferAckPayload.noneAcked) {
        for (
          int i = max(0, _highestContiguousAcked + 1);
          i <= ack.highestContiguousChunkIndex;
          i++
        ) {
          _ackedChunks.add(i);
          _inFlightChunks.remove(i);
          _chunkTimers.remove(i)?.cancel();
          _chunkRetryCounts.remove(i);
        }
        _highestContiguousAcked = max(
          _highestContiguousAcked,
          ack.highestContiguousChunkIndex,
        );
      }

      // 2. Process Selective ACK Bitmap
      if (ack.selectiveBitmap.isNotEmpty) {
        final offset = ack.selectiveBitmapOffset;
        for (final inFlightIdx in _inFlightChunks.keys.toList()) {
          if (inFlightIdx >= offset && ack.isChunkAcknowledged(inFlightIdx)) {
            _ackedChunks.add(inFlightIdx);
            _inFlightChunks.remove(inFlightIdx);
            _chunkTimers.remove(inFlightIdx)?.cancel();
            _chunkRetryCounts.remove(inFlightIdx);
          }
        }
      }

      _bytesAcked = max(_bytesAcked, ack.bytesReceived);
      _emitProgress();

      // 3. Completion check
      final allAcked =
          (metadata.chunkCount == 0) ||
          (_highestContiguousAcked >= metadata.chunkCount - 1) ||
          (_ackedChunks.length >= metadata.chunkCount);

      if (allAcked || ack.ackType == TransferAckType.transferCompleted) {
        _finishSuccess();
      } else {
        _pumpWindow();
      }
    }
  }

  /// Handles incoming NACK packets routed to this transfer.
  Future<void> handleNack(TransferNackPayload nack) async {
    if (_status != TransferStatus.transferring) return;

    if (nack.reason == TransferNackReason.chunkCrcMismatch) {
      AppLogger.warning(
        'OutboundTransferTask',
        'Received CRC NACK for chunk ${nack.chunkIndex}. Fast retransmitting...',
      );
      _chunkTimers.remove(nack.chunkIndex)?.cancel();
      final retries = (_chunkRetryCounts[nack.chunkIndex] ?? 0) + 1;
      if (retries > maxRetries) {
        _failWithTimeout(nack.chunkIndex, retries);
        return;
      }
      _chunkRetryCounts[nack.chunkIndex] = retries;
      final payload = _inFlightChunks[nack.chunkIndex];
      if (payload != null) {
        final packet = VayuPacket(
          packetType: PacketType.transferChunk,
          packetId: DateTime.now().microsecondsSinceEpoch,
          sourceDeviceId: _localIdBytes,
          destinationDeviceId: _remoteIdBytes,
          payload: payload.toBytes(),
        );
        await secureSession.sendEncryptedPacket(packet);
        _startChunkTimer(nack.chunkIndex);
      }
    } else if (nack.reason == TransferNackReason.storageFull ||
        nack.reason == TransferNackReason.ioError) {
      _failWithStorage('Remote receiver storage error: ${nack.details}');
    }
  }

  /// Handles incoming Cancel packets from the receiver.
  void handleCancel(TransferCancelPayload cancel) {
    _cleanupTimers();
    _status =
        (cancel.reason == TransferCancelReason.userCancelled ||
            cancel.reason == TransferCancelReason.declined)
        ? TransferStatus.cancelled
        : TransferStatus.failed;

    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferCancelledException(
          transferId,
          cancel.message.isNotEmpty ? cancel.message : cancel.reason.name,
        ),
      );
    }
  }

  /// Fails the transfer when its authenticated session closes unexpectedly.
  void handleSessionClosed(String reason) {
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }

    _cleanupTimers();
    _status = TransferStatus.failed;
    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferConnectionException(transferId, reason),
      );
    }
  }

  @override
  Future<void> pause() async {
    if (_status != TransferStatus.transferring) return;
    _isPaused = true;
    _status = TransferStatus.paused;
    _pauseCompleter = Completer<void>();
    _cleanupTimers();
    _emitProgress();
    AppLogger.info('OutboundTransferTask', 'Transfer $transferId paused');
  }

  @override
  Future<void> resume() async {
    if (!_isPaused || _status != TransferStatus.paused) return;
    _isPaused = false;
    _status = TransferStatus.transferring;
    _pauseCompleter?.complete();
    _pauseCompleter = null;
    _emitProgress();

    AppLogger.info('OutboundTransferTask', 'Transfer $transferId resumed');

    // Restart timers for in-flight chunks
    for (final chunkIdx in _inFlightChunks.keys) {
      _startChunkTimer(chunkIdx);
    }
    _pumpWindow();
  }

  @override
  Future<void> cancel([String? reason]) async {
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }

    _cleanupTimers();
    _status = TransferStatus.cancelled;

    final cancelPayload = TransferCancelPayload(
      transferId: _transferIdBytes,
      reason: TransferCancelReason.userCancelled,
      message: reason ?? 'Cancelled by sender',
    );

    try {
      final packet = VayuPacket(
        packetType: PacketType.transferCancel,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: _localIdBytes,
        destinationDeviceId: _remoteIdBytes,
        payload: cancelPayload.toBytes(),
      );
      await secureSession.sendEncryptedPacket(packet);
    } catch (_) {}

    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferCancelledException(transferId, reason ?? 'User cancelled'),
      );
    }
  }

  void _finishSuccess() {
    _cleanupTimers();
    _bytesAcked = metadata.totalBytes;
    _status = TransferStatus.completed;
    _emitProgress();
    _closeControllers();

    AppLogger.info(
      'OutboundTransferTask',
      'Transfer $transferId successfully completed in ${DateTime.now().difference(_transferStartTime ?? DateTime.now()).inMilliseconds} ms',
    );

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  void _failWithTimeout(int chunkIdx, int retries) {
    _cleanupTimers();
    _status = TransferStatus.failed;

    final cancelPayload = TransferCancelPayload(
      transferId: _transferIdBytes,
      reason: TransferCancelReason.timeout,
      message: 'Chunk $chunkIdx timed out after $retries retries',
    );

    try {
      final packet = VayuPacket(
        packetType: PacketType.transferCancel,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: _localIdBytes,
        destinationDeviceId: _remoteIdBytes,
        payload: cancelPayload.toBytes(),
      );
      secureSession.sendEncryptedPacket(packet);
    } catch (_) {}

    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferTimeoutException(
          transferId,
          chunkIndex: chunkIdx,
          retryCount: retries,
        ),
      );
    }
  }

  void _failWithStorage(String message) {
    _cleanupTimers();
    _status = TransferStatus.failed;

    final cancelPayload = TransferCancelPayload(
      transferId: _transferIdBytes,
      reason: TransferCancelReason.storageFull,
      message: message,
    );

    try {
      final packet = VayuPacket(
        packetType: PacketType.transferCancel,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: _localIdBytes,
        destinationDeviceId: _remoteIdBytes,
        payload: cancelPayload.toBytes(),
      );
      secureSession.sendEncryptedPacket(packet);
    } catch (_) {}

    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferStorageException(transferId, message),
      );
    }
  }

  void _cleanupTimers() {
    for (final timer in _chunkTimers.values) {
      timer.cancel();
    }
    _chunkTimers.clear();
  }

  void _closeControllers() {
    _isDisposed = true;
    _cleanupTimers();
    if (!_progressController.isClosed) {
      _progressController.close();
    }
  }

  void _emitProgress() {
    if (_progressController.isClosed) return;

    final now = DateTime.now();
    final elapsedMs = now.difference(_lastSampleTime).inMilliseconds;
    if (elapsedMs >= 250) {
      final bytesDelta = _bytesAcked - _lastBytesSample;
      final instantSpeed = (bytesDelta / (elapsedMs / 1000.0));
      _currentSpeed = (_currentSpeed * 0.7) + (instantSpeed * 0.3);
      _lastBytesSample = _bytesAcked;
      _lastSampleTime = now;
    }

    final remainingBytes = metadata.totalBytes - _bytesAcked;
    final etaSeconds = (_currentSpeed > 0 && remainingBytes > 0)
        ? (remainingBytes / _currentSpeed).ceil()
        : null;

    final currentChunk = _highestContiguousAcked == -1
        ? 0
        : _highestContiguousAcked + 1;

    _progressController.add(
      TransferProgress(
        transferId: transferId,
        bytesTransferred: _bytesAcked,
        totalBytes: metadata.totalBytes,
        currentChunkIndex: currentChunk,
        speedBytesPerSecond: _currentSpeed > 0 ? _currentSpeed : 0.0,
        etaSeconds: etaSeconds,
      ),
    );
  }
}

/// Concrete implementation of an active inbound (receiver) transfer task.
///
/// Features:
/// - CRC32 corruption validation on each incoming chunk.
/// - Out-of-order chunk buffering and contiguous sequence advancement.
/// - SACK generation with selective bitmap lookahead.
/// - Duplicate chunk detection and absorption.
/// - Full-payload SHA-256 integrity verification against metadata hash.
/// - Atomic promotion from staging file (`.vayu.tmp`) to final destination.
/// - Immediate cleanup and abort on cancel, hash mismatch, or storage error.
class InboundTransferTask implements TransferTask {
  @override
  final String transferId;

  final String localDeviceId;

  @override
  final String remoteDeviceId;

  final SecureSession secureSession;
  final PayloadDestination destination;

  @override
  final TransferMetadata metadata;

  final int windowSize;

  TransferStatus _status = TransferStatus.transferring;
  final StreamController<TransferProgress> _progressController =
      StreamController<TransferProgress>.broadcast();
  final Completer<void> _doneCompleter = Completer<void>();

  late final Uint8List _transferIdBytes;
  late final Uint8List _localIdBytes;
  late final Uint8List _remoteIdBytes;

  int _highestContiguousChunkIndex = -1;
  final Set<int> _receivedChunks = {};
  int _bytesReceived = 0;
  bool _isDisposed = false;

  DateTime? _transferStartTime;
  int _lastBytesSample = 0;
  DateTime _lastSampleTime = DateTime.now();
  double _currentSpeed = 0.0;

  InboundTransferTask({
    required this.transferId,
    required this.localDeviceId,
    required this.remoteDeviceId,
    required this.secureSession,
    required this.destination,
    required this.metadata,
    this.windowSize = 8,
    int initialContiguousChunkIndex = -1,
    int initialBytesReceived = 0,
  }) {
    _transferIdBytes = parseIdTo16Bytes(transferId);
    _localIdBytes = parseIdTo16Bytes(localDeviceId);
    _remoteIdBytes = parseIdTo16Bytes(remoteDeviceId);
    _highestContiguousChunkIndex = initialContiguousChunkIndex;
    _bytesReceived = initialBytesReceived;
    _transferStartTime = DateTime.now();
    _lastSampleTime = DateTime.now();
    _doneCompleter.future.ignore();
  }

  @override
  TransferStatus get status => _status;

  @override
  Stream<TransferProgress> get progressStream => _progressController.stream;

  /// Future completing when receiving completes and passes SHA-256 verification.
  @override
  Future<void> get done => _doneCompleter.future;

  /// Handles incoming chunk packet.
  Future<void> handleChunk(TransferChunkPayload chunk) async {
    if (_status != TransferStatus.transferring || _isDisposed) return;

    // 1. Verify CRC32
    if (!chunk.verifyCrc()) {
      AppLogger.warning(
        'InboundTransferTask',
        'Chunk ${chunk.chunkIndex} CRC32 mismatch! Sending NACK...',
      );
      final nack = TransferNackPayload(
        transferId: _transferIdBytes,
        chunkIndex: chunk.chunkIndex,
        reason: TransferNackReason.chunkCrcMismatch,
        details: 'CRC32 checksum mismatch',
      );
      await _sendPacket(PacketType.transferNack, nack.toBytes());
      return;
    }

    // 2. Duplicate detection
    if (_receivedChunks.contains(chunk.chunkIndex) ||
        (_highestContiguousChunkIndex != -1 &&
            chunk.chunkIndex <= _highestContiguousChunkIndex)) {
      // Re-send ACK so sender knows chunk was accepted
      await _sendAck(TransferAckType.chunkReceived);
      return;
    }

    // 3. Out-of-order window check
    if (chunk.chunkIndex > _highestContiguousChunkIndex + (windowSize * 4)) {
      AppLogger.warning(
        'InboundTransferTask',
        'Chunk ${chunk.chunkIndex} exceeds sliding window boundary ($windowSize * 4). Sending NACK...',
      );
      final nack = TransferNackPayload(
        transferId: _transferIdBytes,
        chunkIndex: chunk.chunkIndex,
        reason: TransferNackReason.outOfOrderWindowExceeded,
        details: 'Chunk index beyond window horizon',
      );
      await _sendPacket(PacketType.transferNack, nack.toBytes());
      return;
    }

    // 4. Write chunk to destination
    try {
      await destination.writeChunk(chunk.chunkOffset, chunk.chunkData);
      _receivedChunks.add(chunk.chunkIndex);
      _bytesReceived += chunk.chunkLength;
    } catch (e) {
      AppLogger.error('InboundTransferTask', 'Storage write error: $e');
      final nack = TransferNackPayload(
        transferId: _transferIdBytes,
        chunkIndex: chunk.chunkIndex,
        reason: TransferNackReason.storageFull,
        details: e.toString(),
      );
      await _sendPacket(PacketType.transferNack, nack.toBytes());
      await abortWithStorageError('Failed to write chunk: $e');
      return;
    }

    // 5. Advance contiguous index
    while (_receivedChunks.contains(_highestContiguousChunkIndex + 1)) {
      _highestContiguousChunkIndex++;
    }

    // 6. Send cumulative + selective ACK
    await _sendAck(TransferAckType.chunkReceived);
    _emitProgress();

    // 7. Check if all chunks received
    final isDone =
        (metadata.chunkCount == 0) ||
        (_highestContiguousChunkIndex >= metadata.chunkCount - 1);

    if (isDone) {
      await _verifyAndFinalize();
    }
  }

  /// For zero-byte payloads, immediately verifies and finalizes.
  Future<void> verifyIfEmpty() async {
    if (metadata.chunkCount == 0 && !_isDisposed) {
      await _verifyAndFinalize();
    }
  }

  /// Sends SACK packet with cumulative offset and selective bitmask.
  Future<void> _sendAck(TransferAckType ackType) async {
    final offset = _highestContiguousChunkIndex == -1
        ? 0
        : _highestContiguousChunkIndex + 1;

    Uint8List bitmap = Uint8List(0);
    if (offset < metadata.chunkCount) {
      final remainingLookahead = min(256, metadata.chunkCount - offset);
      final bitmapBytes = (remainingLookahead + 7) ~/ 8;
      bitmap = Uint8List(bitmapBytes);

      for (int i = 0; i < remainingLookahead; i++) {
        final targetIdx = offset + i;
        if (_receivedChunks.contains(targetIdx)) {
          final byteIdx = i ~/ 8;
          final bitIdx = i % 8;
          bitmap[byteIdx] |= (1 << bitIdx);
        }
      }
    }

    final ack = TransferAckPayload(
      transferId: _transferIdBytes,
      ackType: ackType,
      highestContiguousChunkIndex: _highestContiguousChunkIndex == -1
          ? TransferAckPayload.noneAcked
          : _highestContiguousChunkIndex,
      bytesReceived: _bytesReceived,
      selectiveBitmapOffset: offset,
      selectiveBitmap: bitmap,
    );

    await _sendPacket(PacketType.transferAck, ack.toBytes());
  }

  /// Verifies full-payload SHA-256 and promotes to target destination.
  Future<void> _verifyAndFinalize() async {
    _status = TransferStatus.verifying;
    _emitProgress();

    AppLogger.info(
      'InboundTransferTask',
      'All chunks received for $transferId. Computing SHA-256...',
    );

    try {
      final computedSha = await destination.computeSha256();
      final expectedSha = metadata.sha256Checksum.toLowerCase();

      if (computedSha.toLowerCase() != expectedSha) {
        AppLogger.error(
          'InboundTransferTask',
          'Checksum verification failed for $transferId. Expected: $expectedSha, Computed: $computedSha',
        );

        final cancel = TransferCancelPayload(
          transferId: _transferIdBytes,
          reason: TransferCancelReason.checksumMismatch,
          message: 'SHA-256 verification failed',
        );
        await _sendPacket(PacketType.transferCancel, cancel.toBytes());
        await destination.abortAndCleanup();

        _status = TransferStatus.failed;
        _emitProgress();
        _closeControllers();

        if (!_doneCompleter.isCompleted) {
          _doneCompleter.completeError(
            TransferChecksumMismatchException(
              transferId,
              expectedHash: expectedSha,
              actualHash: computedSha,
            ),
          );
        }
        return;
      }

      // Checksum verified! Finalize destination
      await destination.finalize();
      await _sendAck(TransferAckType.transferCompleted);

      _status = TransferStatus.completed;
      _emitProgress();
      _closeControllers();

      final elapsedMs = DateTime.now()
          .difference(_transferStartTime ?? DateTime.now())
          .inMilliseconds;
      AppLogger.info(
        'InboundTransferTask',
        'Transfer $transferId successfully verified and finalized in $elapsedMs ms',
      );

      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    } catch (e) {
      AppLogger.error('InboundTransferTask', 'Finalization error: $e');
      await abortWithStorageError('Finalization error: $e');
    }
  }

  /// Handles incoming Cancel packets from sender.
  Future<void> handleCancel(TransferCancelPayload cancel) async {
    await destination.abortAndCleanup();
    _status =
        (cancel.reason == TransferCancelReason.userCancelled ||
            cancel.reason == TransferCancelReason.declined)
        ? TransferStatus.cancelled
        : TransferStatus.failed;

    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferCancelledException(
          transferId,
          cancel.message.isNotEmpty ? cancel.message : cancel.reason.name,
        ),
      );
    }
  }

  /// Aborts the staging destination when its authenticated session closes.
  Future<void> handleSessionClosed(String reason) async {
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }

    await destination.abortAndCleanup();
    _status = TransferStatus.failed;
    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferConnectionException(transferId, reason),
      );
    }
  }

  Future<void> abortWithStorageError(String message) async {
    await destination.abortAndCleanup();
    _status = TransferStatus.failed;
    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferStorageException(transferId, message),
      );
    }
  }

  @override
  Future<void> pause() async {
    // Inbound is receiver-driven by sender's chunks; pausing sets status
    _status = TransferStatus.paused;
    _emitProgress();
  }

  @override
  Future<void> resume() async {
    _status = TransferStatus.transferring;
    _emitProgress();
  }

  @override
  Future<void> cancel([String? reason]) async {
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }

    final cancelPayload = TransferCancelPayload(
      transferId: _transferIdBytes,
      reason: TransferCancelReason.userCancelled,
      message: reason ?? 'Cancelled by receiver',
    );

    try {
      await _sendPacket(PacketType.transferCancel, cancelPayload.toBytes());
    } catch (_) {}

    await destination.abortAndCleanup();
    _status = TransferStatus.cancelled;
    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferCancelledException(transferId, reason ?? 'Receiver cancelled'),
      );
    }
  }

  Future<void> _sendPacket(PacketType type, Uint8List payload) async {
    final packet = VayuPacket(
      packetType: type,
      packetId: DateTime.now().microsecondsSinceEpoch,
      sourceDeviceId: _localIdBytes,
      destinationDeviceId: _remoteIdBytes,
      payload: payload,
    );
    await secureSession.sendEncryptedPacket(packet);
  }

  void _closeControllers() {
    _isDisposed = true;
    if (!_progressController.isClosed) {
      _progressController.close();
    }
  }

  void _emitProgress() {
    if (_progressController.isClosed) return;

    final now = DateTime.now();
    final elapsedMs = now.difference(_lastSampleTime).inMilliseconds;
    if (elapsedMs >= 250) {
      final bytesDelta = _bytesReceived - _lastBytesSample;
      final instantSpeed = (bytesDelta / (elapsedMs / 1000.0));
      _currentSpeed = (_currentSpeed * 0.7) + (instantSpeed * 0.3);
      _lastBytesSample = _bytesReceived;
      _lastSampleTime = now;
    }

    final remainingBytes = metadata.totalBytes - _bytesReceived;
    final etaSeconds = (_currentSpeed > 0 && remainingBytes > 0)
        ? (remainingBytes / _currentSpeed).ceil()
        : null;

    final currentChunk = _highestContiguousChunkIndex == -1
        ? 0
        : _highestContiguousChunkIndex + 1;

    _progressController.add(
      TransferProgress(
        transferId: transferId,
        bytesTransferred: _bytesReceived,
        totalBytes: metadata.totalBytes,
        currentChunkIndex: currentChunk,
        speedBytesPerSecond: _currentSpeed > 0 ? _currentSpeed : 0.0,
        etaSeconds: etaSeconds,
      ),
    );
  }
}
