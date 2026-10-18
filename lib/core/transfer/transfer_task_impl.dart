import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/transfer/resumable_transfers.dart';
import 'package:vayu/core/transfer/transfer_stats.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/transfer/payload_destination.dart';
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
/// - Per-chunk timer with configurable retry threshold (default 5 retries, 10s timeout).
/// - Fast retransmit upon receiving CRC NACKs; window-rejected chunks are re-queued.
/// - Reports completion only after the receiver confirms SHA-256 verification.
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

  /// Base wait for the receiver's verification result once every chunk is
  /// acknowledged; [_verificationTimeout] adds time proportional to file size.
  final Duration verificationTimeout;

  TransferStatus _status = TransferStatus.idle;
  final StreamController<TransferProgress> _progressController =
      StreamController<TransferProgress>.broadcast();
  final Completer<void> _doneCompleter = Completer<void>();

  // Serializes window filling. Every ACK requests a pump; without this, overlapping
  // pumps each saw a stale in-flight count during the async chunk read and pushed
  // chunks past the receiver's horizon.
  bool _pumping = false;
  bool _pumpRequested = false;

  /// Chunks the receiver rejected as beyond its window, resent before new chunks.
  final SplayTreeSet<int> _retransmitQueue = SplayTreeSet<int>();
  Timer? _verificationTimer;

  bool _offerAccepted = false;

  /// True after the offer is sent and before the receiver accepts it. The task
  /// status is already `transferring` then, so UIs use this to say "waiting".
  bool get awaitingAcceptance =>
      !_offerAccepted && _status == TransferStatus.transferring;

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

  /// Receives a timing summary once the transfer ends (speed diagnostics).
  final void Function(TransferStats stats)? onStats;

  /// Chunks read ahead of the one being sent, so disk/bridge reads overlap
  /// with encryption and the socket write instead of running one after another.
  final int readAhead;
  final Map<int, Future<Uint8List>> _prefetched = {};

  /// Chunks that may be encrypting or being written at the same time. Each
  /// send crosses the native bridge twice; waiting for one to finish before
  /// starting the next left the CPU, the cipher and the socket taking turns.
  final int sendPipeline;
  int _sendsInProgress = 0;
  Completer<void>? _sendSlotFreed;

  /// SHA-256 still being computed when the offer went out (`late-hash-v1`);
  /// sent in a digest packet once ready. Null: the offer carried the hash.
  final Future<String>? lateDigest;
  String? _digestReady;
  bool _digestSent = false;

  final Stopwatch _elapsed = Stopwatch();
  Duration _readTime = Duration.zero;
  Duration _sendTime = Duration.zero;
  int _retransmits = 0;
  int _acksReceived = 0;
  bool _statsReported = false;

  OutboundTransferTask({
    required this.transferId,
    required this.localDeviceId,
    required this.remoteDeviceId,
    required this.secureSession,
    required this.source,
    required this.metadata,
    this.windowSize = 8,
    // TCP already retransmits lost segments, so a chunk timeout means the path or
    // the peer stalled. Generous limits ride out GC pauses and slow storage.
    this.chunkTimeout = const Duration(seconds: 10),
    this.maxRetries = 5,
    this.verificationTimeout = const Duration(seconds: 30),
    this.onStats,
    this.readAhead = 4,
    this.sendPipeline = 3,
    this.lateDigest,
  }) {
    _transferIdBytes = parseIdTo16Bytes(transferId);
    _localIdBytes = parseIdTo16Bytes(localDeviceId);
    _remoteIdBytes = parseIdTo16Bytes(remoteDeviceId);
    _doneCompleter.future.ignore();
    // Listened to at once so a hash that already failed is never unhandled.
    lateDigest?.then(
      (sha256Hex) {
        _digestReady = sha256Hex;
        _maybeSendDigest();
      },
      onError: (Object e) =>
          _failWithSourceError('Could not hash the file: $e'),
    );
  }

  // The receiver hashes the whole file before confirming; allow ~10 MB/s on slow phones.
  Duration get _verificationTimeout =>
      verificationTimeout +
      Duration(milliseconds: metadata.totalBytes ~/ (10 * 1024));

  @override
  TransferStatus get status => _status;

  @override
  Stream<TransferProgress> get progressStream => _progressController.stream;

  /// Most recent progress snapshot. The progress stream does not replay, so a
  /// screen opened after an update (or after completion) starts from this.
  TransferProgress? lastProgress;

  /// Future completing when the transfer completes successfully or with error.
  @override
  Future<void> get done => _doneCompleter.future;

  /// Begins the outbound transfer pipeline.
  Future<void> start() async {
    if (_status != TransferStatus.idle) return;
    _status = TransferStatus.transferring;
    _transferStartTime = DateTime.now();
    _elapsed.start();
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

  bool _isChunkAcked(int chunkIdx) =>
      _ackedChunks.contains(chunkIdx) ||
      (_highestContiguousAcked != -1 && chunkIdx <= _highestContiguousAcked);

  /// Pushes unacknowledged chunks within the sliding window, one pump at a time.
  Future<void> _pumpWindow() async {
    if (_pumping) {
      _pumpRequested = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpRequested = false;
        await _pumpOnce();
      } while (_pumpRequested);
    } finally {
      _pumping = false;
    }
  }

  Future<void> _pumpOnce() async {
    if (_isPaused || _status != TransferStatus.transferring || _isDisposed) {
      return;
    }

    while (_inFlightChunks.length < windowSize && _retransmitQueue.isNotEmpty) {
      final chunkIdx = _retransmitQueue.first;
      _retransmitQueue.remove(chunkIdx);
      if (_isChunkAcked(chunkIdx) || _inFlightChunks.containsKey(chunkIdx)) {
        continue;
      }
      await _sendChunk(chunkIdx);
      if (_status != TransferStatus.transferring) return;
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
      _prefetchFrom(_nextChunkToSend);
      await _sendChunk(chunkIdx);
    }
  }

  Future<Uint8List> _readChunkAt(int chunkIdx) {
    final offset = chunkIdx * metadata.chunkSize;
    final remaining = metadata.totalBytes - offset;
    final length = remaining > metadata.chunkSize
        ? metadata.chunkSize
        : remaining;
    return source.readChunk(offset, length);
  }

  /// Starts reads for up to [readAhead] chunks from [first] that are neither
  /// acknowledged nor already being read.
  void _prefetchFrom(int first) {
    for (
      var idx = first;
      idx < metadata.chunkCount && idx < first + readAhead;
      idx++
    ) {
      if (_prefetched.containsKey(idx) || _isChunkAcked(idx)) continue;
      // ignore(): a read never awaited (task cancelled) must not surface as
      // an unhandled error; awaiting it later still reports the failure.
      _prefetched[idx] = _readChunkAt(idx)..ignore();
    }
  }

  Future<void> _sendChunk(int chunkIdx) async {
    if (_status != TransferStatus.transferring || _isDisposed) return;

    final offset = chunkIdx * metadata.chunkSize;

    final Uint8List chunkBytes;
    final readClock = Stopwatch()..start();
    try {
      chunkBytes =
          await (_prefetched.remove(chunkIdx) ?? _readChunkAt(chunkIdx));
      _readTime += readClock.elapsed;
    } catch (e) {
      AppLogger.error(
        'OutboundTransferTask',
        'Failed to read chunk $chunkIdx',
        error: e,
      );
      _failWithSourceError('Failed to read chunk $chunkIdx: $e');
      return;
    }
    if (_status != TransferStatus.transferring || _isDisposed) return;

    final chunkPayload = TransferChunkPayload.create(
      transferId: _transferIdBytes,
      chunkIndex: chunkIdx,
      chunkOffset: offset,
      chunkData: chunkBytes,
    );
    _inFlightChunks[chunkIdx] = chunkPayload;
    while (_sendsInProgress >= sendPipeline) {
      await (_sendSlotFreed ??= Completer<void>()).future;
    }
    if (_status != TransferStatus.transferring || _isDisposed) return;
    _sendsInProgress++;
    // Not awaited: the pump goes on to read and encrypt the next chunk while
    // this one is written. The session keeps packets in order.
    _transmitChunk(chunkIdx, chunkPayload).whenComplete(() {
      _sendsInProgress--;
      final freed = _sendSlotFreed;
      _sendSlotFreed = null;
      freed?.complete();
    }).ignore();
  }

  /// Sends [payload] and arms its retransmit timer.
  ///
  /// A failed send is a connection problem, never a storage one: the chunk
  /// stays in flight so its timer retransmits it, and the task fails only when
  /// the session itself is gone (or retries run out).
  Future<void> _transmitChunk(
    int chunkIdx,
    TransferChunkPayload payload,
  ) async {
    final packet = VayuPacket(
      packetType: PacketType.transferChunk,
      packetId: DateTime.now().microsecondsSinceEpoch,
      sourceDeviceId: _localIdBytes,
      destinationDeviceId: _remoteIdBytes,
      payload: payload.toBytes(),
    );
    final sendClock = Stopwatch()..start();
    try {
      await secureSession.sendEncryptedPacket(packet);
      _sendTime += sendClock.elapsed;
    } catch (e) {
      AppLogger.warning(
        'OutboundTransferTask',
        'Sending chunk $chunkIdx failed, will retry: $e',
      );
      if (!secureSession.isEstablished) {
        handleSessionClosed('Connection lost while sending: $e');
        return;
      }
    }
    if (_status == TransferStatus.transferring && !_isDisposed) {
      _startChunkTimer(chunkIdx);
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
      _retransmits++;
      await _transmitChunk(chunkIdx, payload);
    }
  }

  /// Sends the late hash once it is ready and the receiver has accepted:
  /// before that the receiver has no task to give it to.
  Future<void> _maybeSendDigest() async {
    final sha256Hex = _digestReady;
    if (sha256Hex == null || !_offerAccepted || _digestSent) return;
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }
    _digestSent = true;
    final digest = TransferDigestPayload(
      transferId: _transferIdBytes,
      sha256Hash: parseSha256HexToBytes(sha256Hex),
    );
    try {
      await secureSession.sendEncryptedPacket(
        VayuPacket(
          packetType: PacketType.transferDigest,
          packetId: DateTime.now().microsecondsSinceEpoch,
          sourceDeviceId: _localIdBytes,
          destinationDeviceId: _remoteIdBytes,
          payload: digest.toBytes(),
        ),
      );
    } catch (e) {
      handleSessionClosed('Connection lost while sending the file hash: $e');
      return;
    }
    // The receiver cannot confirm before it has the hash, so the wait for its
    // answer starts only now when every chunk was delivered first.
    if (_status == TransferStatus.verifying) _startVerificationTimer();
  }

  /// Every byte is delivered; wait for the receiver to confirm its SHA-256 check.
  void _awaitReceiverVerification() {
    if (_status == TransferStatus.verifying) return;
    for (final timer in _chunkTimers.values) {
      timer.cancel();
    }
    _chunkTimers.clear();
    _inFlightChunks.clear();
    _status = TransferStatus.verifying;
    _emitProgress();
    if (lateDigest == null || _digestSent) _startVerificationTimer();
  }

  void _startVerificationTimer() {
    _verificationTimer?.cancel();
    _verificationTimer = Timer(_verificationTimeout, () {
      if (_status != TransferStatus.verifying) return;
      AppLogger.warning(
        'OutboundTransferTask',
        'Receiver did not confirm verification of $transferId in time',
      );
      _cleanupTimers();
      _status = TransferStatus.failed;
      _emitProgress();
      _closeControllers();
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.completeError(
          TransferVerificationTimeoutException(transferId),
        );
      }
    });
  }

  /// Handles incoming ACK packets routed to this transfer.
  void handleAck(TransferAckPayload ack) {
    _acksReceived++;
    if (_status != TransferStatus.transferring &&
        _status != TransferStatus.idle &&
        _status != TransferStatus.verifying) {
      return;
    }
    if (_status == TransferStatus.verifying &&
        ack.ackType != TransferAckType.transferCompleted) {
      return;
    }

    if (ack.ackType == TransferAckType.offerAccepted ||
        ack.ackType == TransferAckType.resumeCheckpoint) {
      _status = TransferStatus.transferring;
      _offerAccepted = true;
      _maybeSendDigest();

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

      // 3. Completion: only the receiver's verified confirmation is success.
      if (ack.ackType == TransferAckType.transferCompleted) {
        _finishSuccess();
        return;
      }

      final allAcked =
          (metadata.chunkCount == 0) ||
          (_highestContiguousAcked >= metadata.chunkCount - 1) ||
          (_ackedChunks.length >= metadata.chunkCount);

      if (allAcked) {
        _awaitReceiverVerification();
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
        _retransmits++;
        await _transmitChunk(nack.chunkIndex, payload);
      }
    } else if (nack.reason == TransferNackReason.outOfOrderWindowExceeded) {
      // The receiver dropped this chunk because it arrived too far ahead.
      // Queue it for resend once the window advances; it is not a delivery failure.
      final idx = nack.chunkIndex;
      _chunkTimers.remove(idx)?.cancel();
      _inFlightChunks.remove(idx);
      if (!_isChunkAcked(idx)) {
        _retransmitQueue.add(idx);
      }
      _pumpWindow();
    } else if (nack.reason == TransferNackReason.storageFull ||
        nack.reason == TransferNackReason.ioError) {
      _failWithStorage(
        'Receiver could not save the file: ${nack.details}',
        outOfSpace: nack.reason == TransferNackReason.storageFull,
        notifyPeer: false,
      );
    }
  }

  /// Handles incoming Cancel packets from the receiver.
  void handleCancel(TransferCancelPayload cancel) {
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }
    // Storage problems on the receiver keep their real meaning for the UI.
    if (cancel.reason == TransferCancelReason.storageFull ||
        cancel.reason == TransferCancelReason.ioError) {
      _failWithStorage(
        cancel.message.isNotEmpty ? cancel.message : cancel.reason.name,
        outOfSpace: cancel.reason == TransferCancelReason.storageFull,
        notifyPeer: false,
      );
      return;
    }
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

  void _reportStats(bool succeeded) {
    if (_statsReported || onStats == null) return;
    _statsReported = true;
    _elapsed.stop();
    onStats!(
      TransferStats(
        outbound: true,
        bytes: succeeded ? metadata.totalBytes : _bytesAcked,
        chunkSize: metadata.chunkSize,
        windowChunks: windowSize,
        elapsed: _elapsed.elapsed,
        ioTime: _readTime,
        sendTime: _sendTime,
        retransmits: _retransmits,
        acks: _acksReceived,
        succeeded: succeeded,
      ),
    );
  }

  void _finishSuccess() {
    _reportStats(true);
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
    _reportStats(false);
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

  /// Fails because the receiver reported it could not save the file. The
  /// receiver already knows, so no cancel is sent back unless [notifyPeer].
  void _failWithStorage(
    String message, {
    required bool outOfSpace,
    bool notifyPeer = true,
  }) {
    _fail(
      TransferStorageException(transferId, message, outOfSpace: outOfSpace),
      notifyReason: notifyPeer
          ? (outOfSpace
                ? TransferCancelReason.storageFull
                : TransferCancelReason.ioError)
          : null,
      message: message,
    );
  }

  /// Fails because this device could not read its own file; tells the
  /// receiver so it discards the partial file with an accurate reason.
  void _failWithSourceError(String message) {
    _fail(
      TransferSourceException(transferId, message),
      notifyReason: TransferCancelReason.sourceUnreadable,
      message: 'The sender could not read the file',
    );
  }

  void _fail(
    TransferException error, {
    TransferCancelReason? notifyReason,
    required String message,
  }) {
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }
    _reportStats(false);
    _cleanupTimers();
    _status = TransferStatus.failed;

    if (notifyReason != null) {
      final cancelPayload = TransferCancelPayload(
        transferId: _transferIdBytes,
        reason: notifyReason,
        message: message,
      );
      final packet = VayuPacket(
        packetType: PacketType.transferCancel,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: _localIdBytes,
        destinationDeviceId: _remoteIdBytes,
        payload: cancelPayload.toBytes(),
      );
      secureSession.sendEncryptedPacket(packet).catchError((_) {});
    }

    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(error);
    }
  }

  void _cleanupTimers() {
    for (final timer in _chunkTimers.values) {
      timer.cancel();
    }
    _chunkTimers.clear();
    _prefetched.clear();
    _verificationTimer?.cancel();
    _verificationTimer = null;
    // Release a pump waiting for a send slot; it sees the end state and stops.
    final waiting = _sendSlotFreed;
    _sendSlotFreed = null;
    waiting?.complete();
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

    final progress = TransferProgress(
      transferId: transferId,
      bytesTransferred: _bytesAcked,
      totalBytes: metadata.totalBytes,
      currentChunkIndex: currentChunk,
      speedBytesPerSecond: _currentSpeed > 0 ? _currentSpeed : 0.0,
      etaSeconds: etaSeconds,
    );
    lastProgress = progress;
    _progressController.add(progress);
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

  /// In-order chunks acknowledged together. Every ACK is an encrypted packet
  /// (a native bridge call on Android), so acking every chunk wasted time.
  /// Kept small so an older sender with an 8-chunk window never stalls.
  final int ackEvery;

  /// Longest an in-order chunk waits for its ACK to be batched.
  final Duration ackDelay;
  int _unackedChunks = 0;
  Timer? _ackTimer;

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

  /// Receives a timing summary once the transfer ends (speed diagnostics).
  final void Function(TransferStats stats)? onStats;
  final Stopwatch _elapsed = Stopwatch()..start();
  Duration _writeTime = Duration.zero;
  int _acksSent = 0;

  /// The sender's SHA-256: from the offer, or from a later digest packet when
  /// the offer was sent before hashing finished (`late-hash-v1`).
  final Completer<String> _expectedSha = Completer<String>();

  /// Longest the final check waits for a late hash once every byte is here.
  /// The sender hashes while it sends, so the hash is normally already here.
  final Duration digestTimeout;

  /// Given the received prefix when the connection drops, so the same file
  /// offered again continues from there. Null: the partial file is deleted.
  final void Function(PartialTransfer partial)? onInterrupted;

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
    this.onStats,
    this.ackEvery = 2,
    this.ackDelay = const Duration(milliseconds: 15),
    this.onInterrupted,
    this.digestTimeout = const Duration(minutes: 10),
  }) {
    if (!metadata.hashDeferred) _expectedSha.complete(metadata.sha256Checksum);
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

  /// Most recent progress snapshot. The progress stream does not replay, so a
  /// screen opened after an update (or after completion) starts from this.
  TransferProgress? lastProgress;

  /// Future completing when receiving completes and passes SHA-256 verification.
  @override
  Future<void> get done => _doneCompleter.future;

  // Chunks are processed strictly one at a time. The engine does not await
  // handlers, and overlapping handlers used to run the final verification
  // twice (the second one found the staging file already renamed and failed a
  // finished transfer) and to write retransmitted duplicates twice.
  Future<void> _chunkQueue = Future<void>.value();
  bool _finalizing = false;

  /// Handles an incoming chunk packet. Calls are queued and run in order.
  Future<void> handleChunk(TransferChunkPayload chunk) {
    final next = _chunkQueue.then((_) => _processChunk(chunk));
    _chunkQueue = next.catchError((Object e) {
      AppLogger.warning('InboundTransferTask', 'Chunk handling failed: $e');
    });
    return _chunkQueue;
  }

  Future<void> _processChunk(TransferChunkPayload chunk) async {
    if (_status != TransferStatus.transferring || _isDisposed || _finalizing) {
      return;
    }

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
      _sendAckQuietly(TransferAckType.chunkReceived);
      return;
    }

    // 3. Out-of-order window check. The horizon covers at least 16 MiB so a
    // sender using a larger window for big chunks is never rejected.
    final horizon = max(
      windowSize * 4,
      (16 * 1024 * 1024) ~/ max(1, metadata.chunkSize),
    );
    if (chunk.chunkIndex > _highestContiguousChunkIndex + horizon) {
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
    final writeClock = Stopwatch()..start();
    try {
      await destination.writeChunk(chunk.chunkOffset, chunk.chunkData);
      _writeTime += writeClock.elapsed;
      _receivedChunks.add(chunk.chunkIndex);
      _bytesReceived += chunk.chunkLength;
    } catch (e) {
      // A cancel or session close may have aborted the destination meanwhile.
      if (_status != TransferStatus.transferring || _isDisposed) return;
      final outOfSpace = isOutOfSpaceError(e);
      AppLogger.error(
        'InboundTransferTask',
        'Storage write error (outOfSpace=$outOfSpace): $e',
      );
      final nack = TransferNackPayload(
        transferId: _transferIdBytes,
        chunkIndex: chunk.chunkIndex,
        reason: outOfSpace
            ? TransferNackReason.storageFull
            : TransferNackReason.ioError,
        details: outOfSpace ? 'Not enough storage space' : 'Write failed',
      );
      try {
        await _sendPacket(PacketType.transferNack, nack.toBytes());
      } catch (_) {}
      await abortWithStorageError(
        'Failed to write chunk: $e',
        outOfSpace: outOfSpace,
      );
      return;
    }

    // 5. Advance contiguous index
    while (_receivedChunks.contains(_highestContiguousChunkIndex + 1)) {
      _highestContiguousChunkIndex++;
    }

    // 7. Check if all chunks received
    final isDone =
        (metadata.chunkCount == 0) ||
        (_highestContiguousChunkIndex >= metadata.chunkCount - 1);

    // 6. Cumulative + selective ACK, batched for in-order chunks. A gap (a
    // chunk the sender must resend) or the last chunk is acknowledged at once.
    final hasGap = _receivedChunks.length > _highestContiguousChunkIndex + 1;
    _unackedChunks++;
    if (isDone || hasGap || _unackedChunks >= ackEvery) {
      _flushAck();
    } else {
      _ackTimer ??= Timer(ackDelay, _flushAck);
    }
    _emitProgress();

    if (isDone) {
      await _verifyAndFinalize();
    }
  }

  void _flushAck() {
    _ackTimer?.cancel();
    _ackTimer = null;
    if (_unackedChunks == 0) return;
    _unackedChunks = 0;
    if (_status != TransferStatus.transferring &&
        _status != TransferStatus.verifying) {
      return;
    }
    // Built from the current state synchronously; delivery does not hold up
    // the next chunk.
    _sendAckQuietly(TransferAckType.chunkReceived);
  }

  void _sendAckQuietly(TransferAckType type) {
    _sendAck(type).catchError((Object e) {
      AppLogger.warning('InboundTransferTask', 'Sending ACK failed: $e');
    });
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

    _acksSent++;
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

  /// Takes the late SHA-256 announced by the sender. The first one counts.
  void handleDigest(TransferDigestPayload digest) {
    if (!metadata.hashDeferred || _expectedSha.isCompleted) return;
    _expectedSha.complete(digest.sha256Hex);
  }

  /// Verifies full-payload SHA-256 and promotes to target destination.
  Future<void> _verifyAndFinalize() async {
    if (_finalizing) return;
    _finalizing = true;
    _status = TransferStatus.verifying;
    _emitProgress();

    AppLogger.info(
      'InboundTransferTask',
      'All chunks received for $transferId. Computing SHA-256...',
    );

    final verifyClock = Stopwatch()..start();
    void report(bool succeeded) {
      _elapsed.stop();
      onStats?.call(
        TransferStats(
          outbound: false,
          bytes: _bytesReceived,
          chunkSize: metadata.chunkSize,
          elapsed: _elapsed.elapsed,
          ioTime: _writeTime,
          verifyTime: verifyClock.elapsed,
          acks: _acksSent,
          succeeded: succeeded,
        ),
      );
    }

    try {
      final computedSha = await destination.computeSha256();
      final String expectedSha;
      try {
        expectedSha = (await _expectedSha.future.timeout(digestTimeout))
            .toLowerCase();
      } on TimeoutException {
        AppLogger.warning(
          'InboundTransferTask',
          'Sender never sent the hash of $transferId',
        );
        await _failUnverified();
        report(false);
        return;
      }
      if (_status != TransferStatus.verifying || _isDisposed) return;

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
        report(false);

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
      report(true);
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
      final outOfSpace = isOutOfSpaceError(e);
      // Tell the sender now; otherwise it waits for a verification timeout and
      // reports a generic failure.
      final cancel = TransferCancelPayload(
        transferId: _transferIdBytes,
        reason: outOfSpace
            ? TransferCancelReason.storageFull
            : TransferCancelReason.ioError,
        message: outOfSpace
            ? 'Not enough storage space on the receiving device'
            : 'The receiving device could not save the file',
      );
      try {
        await _sendPacket(PacketType.transferCancel, cancel.toBytes());
      } catch (_) {}
      await abortWithStorageError(
        'Finalization error: $e',
        outOfSpace: outOfSpace,
      );
    }
  }

  /// Gives up on a file whose late hash never arrived: it cannot be verified.
  Future<void> _failUnverified() async {
    final cancel = TransferCancelPayload(
      transferId: _transferIdBytes,
      reason: TransferCancelReason.timeout,
      message: 'The file hash never arrived',
    );
    try {
      await _sendPacket(PacketType.transferCancel, cancel.toBytes());
    } catch (_) {}
    await destination.abortAndCleanup();
    _status = TransferStatus.failed;
    _emitProgress();
    _closeControllers();
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferVerificationTimeoutException(transferId),
      );
    }
  }

  /// Handles incoming Cancel packets from sender.
  Future<void> handleCancel(TransferCancelPayload cancel) async {
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }
    _status =
        (cancel.reason == TransferCancelReason.userCancelled ||
            cancel.reason == TransferCancelReason.declined)
        ? TransferStatus.cancelled
        : TransferStatus.failed;
    await destination.abortAndCleanup();

    _emitProgress();
    _closeControllers();

    final message = cancel.message.isNotEmpty
        ? cancel.message
        : cancel.reason.name;
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        cancel.reason == TransferCancelReason.sourceUnreadable
            ? TransferSourceException(transferId, message)
            : TransferCancelledException(transferId, message),
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

    // Status first, so a queued chunk handler sees the task is over.
    _status = TransferStatus.failed;
    _ackTimer?.cancel();
    final keep = onInterrupted;
    final dest = destination;
    final chunks = _highestContiguousChunkIndex + 1;
    if (keep != null &&
        dest is FilePayloadDestination &&
        !_finalizing &&
        chunks > 0 &&
        chunks < metadata.chunkCount) {
      final staging = await dest.detachKeepingStaging();
      keep(
        PartialTransfer(
          stagingPath: staging,
          contiguousChunks: chunks,
          contiguousBytes: min(
            chunks * metadata.chunkSize,
            metadata.totalBytes,
          ),
        ),
      );
    } else {
      await destination.abortAndCleanup();
    }
    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferConnectionException(transferId, reason),
      );
    }
  }

  Future<void> abortWithStorageError(
    String message, {
    bool outOfSpace = false,
  }) async {
    if (_status == TransferStatus.completed ||
        _status == TransferStatus.cancelled ||
        _status == TransferStatus.failed) {
      return;
    }
    _status = TransferStatus.failed;
    await destination.abortAndCleanup();
    _emitProgress();
    _closeControllers();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(
        TransferStorageException(transferId, message, outOfSpace: outOfSpace),
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

    _status = TransferStatus.cancelled;
    try {
      await _sendPacket(PacketType.transferCancel, cancelPayload.toBytes());
    } catch (_) {}

    await destination.abortAndCleanup();
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
    _ackTimer?.cancel();
    _ackTimer = null;
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

    final progress = TransferProgress(
      transferId: transferId,
      bytesTransferred: _bytesReceived,
      totalBytes: metadata.totalBytes,
      currentChunkIndex: currentChunk,
      speedBytesPerSecond: _currentSpeed > 0 ? _currentSpeed : 0.0,
      etaSeconds: etaSeconds,
    );
    lastProgress = progress;
    _progressController.add(progress);
  }
}
