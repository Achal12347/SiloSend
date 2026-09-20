import 'dart:typed_data';

import 'package:silosend_datasharing_app/domain/models/transfer_models.dart';

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
  Stream<Uint8List> openStream({int startByte = 0});
}

/// Active transfer task monitored by the UI.
abstract class TransferTask {
  String get transferId;
  String get remoteDeviceId;
  TransferStatus get status;
  TransferMetadata get metadata;
  Stream<TransferProgress> get progressStream;

  Future<void> pause();
  Future<void> resume();
  Future<void> cancel();
}

/// Incoming transfer offer received from a remote peer.
class IncomingTransferRequest {
  final String transferId;
  final String senderDeviceId;
  final TransferMetadata metadata;

  const IncomingTransferRequest({
    required this.transferId,
    required this.senderDeviceId,
    required this.metadata,
  });

  /// The destination file path when accepted.
  Future<TransferTask> accept(String saveDestinationPath) {
    throw UnimplementedError();
  }

  Future<void> decline() {
    throw UnimplementedError();
  }
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
}
