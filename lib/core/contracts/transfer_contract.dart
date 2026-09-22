import 'dart:typed_data';

import 'package:silosend_datasharing_app/core/errors/app_error.dart';
import 'package:silosend_datasharing_app/domain/models/transfer_models.dart';

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

/// Thrown when destination storage is full or file IO fails.
class TransferStorageException extends TransferException {
  TransferStorageException(String transferId, String message)
    : super(transferId, 'Storage error - $message');
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

  const IncomingTransferRequest({
    required this.transferId,
    required this.senderDeviceId,
    required this.metadata,
    required this.onAccept,
    this.onAcceptCustom,
    required this.onDecline,
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
}

/// Abstract contract for the unified, transport-independent transfer engine.
abstract class TransferEngine {
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
