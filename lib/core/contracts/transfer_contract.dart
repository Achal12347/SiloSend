import 'dart:typed_data';

import 'package:vayu/core/errors/app_error.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

/// Supported transferable payload types.
enum PayloadType {
  file(0x01),
  contact(0x02),
  message(0x03),
  rawStream(0x04);

  final int code;
  const PayloadType(this.code);

  static PayloadType fromCode(int code) {
    for (final type in PayloadType.values) {
      if (type.code == code) return type;
    }
    throw FormatException(
      'Unknown payload type code: 0x${code.toRadixString(16)}',
    );
  }
}

/// Base exception for all transfer engine errors.
abstract class TransferException extends AppError {
  final String transferId;

  TransferException(this.transferId, String message)
    : super('Transfer $transferId: $message');
}

/// Thrown when a transfer is cancelled by the local user or remote peer.
class TransferCancelledException extends TransferException {
  final String reason;

  TransferCancelledException(
    String transferId, [
    this.reason = 'Transfer was cancelled',
  ]) : super(transferId, 'Cancelled - $reason');
}

/// Thrown when the end-to-end full payload SHA-256 digest fails verification.
class TransferChecksumMismatchException extends TransferException {
  final String expectedHash;
  final String actualHash;

  TransferChecksumMismatchException(
    String transferId, {
    required this.expectedHash,
    required this.actualHash,
  }) : super(
         transferId,
         'Checksum verification failed! Expected: $expectedHash, Computed: $actualHash',
       );
}

/// Thrown when chunk delivery times out after maximum retries are exhausted.
class TransferTimeoutException extends TransferException {
  final int chunkIndex;
  final int retryCount;

  TransferTimeoutException(
    String transferId, {
    required this.chunkIndex,
    required this.retryCount,
  }) : super(
         transferId,
         'Delivery timed out on chunk $chunkIndex after $retryCount retries',
       );
}

/// Thrown when the destination file cannot be written or promoted.
///
/// [outOfSpace] is true only when the OS reported a full disk (or the free-space
/// check failed); every other write problem is a plain I/O error. The UI must
/// not tell the user to free up space unless [outOfSpace] is set.
class TransferStorageException extends TransferException {
  final bool outOfSpace;

  TransferStorageException(
    String transferId,
    String message, {
    this.outOfSpace = false,
  }) : super(transferId, 'Storage error - $message');
}

/// Thrown before accepting a transfer when the destination has too little
/// free space for it.
class InsufficientStorageException extends TransferStorageException {
  final int requiredBytes;
  final int freeBytes;

  InsufficientStorageException(
    String transferId, {
    required this.requiredBytes,
    required this.freeBytes,
  }) : super(
         transferId,
         'needs $requiredBytes bytes, $freeBytes free',
         outOfSpace: true,
       );
}

/// Thrown when the sender cannot read its own source file (for example the
/// file was deleted or its storage permission was revoked mid-transfer).
class TransferSourceException extends TransferException {
  TransferSourceException(String transferId, String message)
    : super(transferId, 'Source unreadable - $message');
}

/// Thrown when the authenticated session closes before a transfer completes.
class TransferConnectionException extends TransferException {
  TransferConnectionException(String transferId, String message)
    : super(transferId, 'Connection lost - $message');
}

/// Thrown when every chunk was delivered but the receiver never confirmed that
/// its SHA-256 check passed, so success cannot be claimed.
class TransferVerificationTimeoutException extends TransferException {
  TransferVerificationTimeoutException(String transferId)
    : super(transferId, 'Receiver did not confirm file verification');
}

/// Current lifecycle status of an individual transfer.
enum TransferStatus {
  idle,
  queued,
  connecting,
  transferring,
  paused,
  verifying,
  completed,
  cancelled,
  failed,
}

/// Abstract source of data for a transfer (file on disk, memory buffer, or stream).
abstract class PayloadSource {
  int get length;
  Future<Uint8List> readChunk(int offset, int length);
  Stream<Uint8List> openStream({int startByte = 0});
  Future<String> computeSha256();
  Future<void> close() async {}
}

/// Abstract destination sink for receiving transferred data.
abstract class PayloadDestination {
  int get totalBytes;
  Future<void> writeChunk(int offset, Uint8List data);
  Future<String> computeSha256();
  Future<void> finalize();
  Future<void> abortAndCleanup();
  Future<void> close() async {}
}

/// Active transfer task monitored by the UI or orchestrator.
abstract class TransferTask {
  String get transferId;
  String get remoteDeviceId;
  TransferStatus get status;
  TransferMetadata get metadata;
  Stream<TransferProgress> get progressStream;
  Future<void> get done;

  Future<void> pause();
  Future<void> resume();
  Future<void> cancel([String? reason]);
}

/// Incoming transfer offer received from a remote peer.
class IncomingTransferRequest {
  final String transferId;
  final String senderDeviceId;
  final TransferMetadata metadata;
  final Future<TransferTask> Function(String saveDestinationPath) onAccept;
  final Future<TransferTask> Function(PayloadDestination destination)?
  onAcceptCustom;
  final Future<void> Function([String? reason]) onDecline;
  final Future<void> Function(TransferCancelReason code, String message)?
  onReject;

  /// Set only by the local engine, after it matched this file against a
  /// consent grant the user gave for this batch. Never derived from anything
  /// the sender claims. When set, the file may be accepted without a prompt.
  final String? authorizedBatchId;

  const IncomingTransferRequest({
    required this.transferId,
    required this.senderDeviceId,
    required this.metadata,
    required this.onAccept,
    this.onAcceptCustom,
    required this.onDecline,
    this.onReject,
    this.authorizedBatchId,
  });

  /// Accepts the transfer and saves to [saveDestinationPath].
  Future<TransferTask> accept(String saveDestinationPath) =>
      onAccept(saveDestinationPath);

  /// Accepts the transfer with a custom [PayloadDestination].
  Future<TransferTask> acceptWithDestination(PayloadDestination destination) {
    final custom = onAcceptCustom;
    if (custom != null) {
      return custom(destination);
    }
    throw UnsupportedError('Custom destination not supported for this request');
  }

  /// Declines the incoming transfer offer.
  Future<void> decline([String? reason]) => onDecline(reason);

  /// Declines with a specific wire [code] (for example
  /// [TransferCancelReason.storageFull]) so the sender can show the real cause.
  Future<void> declineWithCode(TransferCancelReason code, String message) {
    final reject = onReject;
    return reject != null ? reject(code, message) : onDecline(message);
  }
}

/// One offer covering several files, answered once by the receiving user.
class IncomingBatchRequest {
  final String batchId;
  final String senderDeviceId;
  final List<BatchManifestEntry> files;
  final Future<void> Function() onAccept;
  final Future<void> Function(TransferCancelReason code, String message)
  onReject;

  const IncomingBatchRequest({
    required this.batchId,
    required this.senderDeviceId,
    required this.files,
    required this.onAccept,
    required this.onReject,
  });

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  /// Approves every file in [files] from this sender for this batch only.
  Future<void> accept() => onAccept();

  Future<void> decline([String? reason]) => onReject(
    TransferCancelReason.declined,
    reason ?? 'Declined by recipient',
  );

  Future<void> declineWithCode(TransferCancelReason code, String message) =>
      onReject(code, message);
}

/// Thrown on the sender when the receiver refuses a whole batch.
class TransferBatchDeclinedException extends AppError {
  final TransferCancelReason reason;

  TransferBatchDeclinedException(this.reason, String message) : super(message);

  bool get outOfSpace => reason == TransferCancelReason.storageFull;
}

/// Abstract contract for the unified, transport-independent transfer engine.
abstract class TransferEngine {
  /// Chunk size suited to the link currently used with [targetDeviceId]
  /// (small for BLE, larger for Wi-Fi/LAN).
  int chunkSizeFor(String targetDeviceId);

  /// Whether [targetDeviceId]'s build understands batch offers (otherwise
  /// files must be offered one by one).
  bool supportsBatchOffers(String targetDeviceId);

  /// Offers [files] to [targetDeviceId] as one batch and waits for the
  /// receiver's single answer. Throws [TransferBatchDeclinedException] when
  /// refused and [TransferConnectionException] if the session closes first.
  Future<void> offerBatch({
    required String targetDeviceId,
    required String batchId,
    required List<BatchManifestEntry> files,
    Duration timeout,
  });

  /// Stream of incoming batch offers awaiting one accept/decline decision.
  Stream<IncomingBatchRequest> get incomingBatchRequests;

  /// Initiates an outbound data transfer to [targetDeviceId].
  Future<TransferTask> sendPayload({
    required String targetDeviceId,
    required PayloadSource source,
    required TransferMetadata metadata,
  });

  /// Stream of incoming transfer requests from remote peers.
  Stream<IncomingTransferRequest> get incomingTransferRequests;

  /// Currently active transfer tasks (both outbound and inbound).
  List<TransferTask> get activeTransfers;

  /// Disposes resources, cancelling active transfers.
  Future<void> dispose();
}
