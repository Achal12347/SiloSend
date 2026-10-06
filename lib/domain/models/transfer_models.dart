import 'dart:convert';
import 'dart:typed_data';

import 'package:vayu/core/contracts/transfer_contract.dart';

/// Metadata describing a transferable payload (file, contact, message, or data stream).
class TransferMetadata {
  final String transferId;
  final String fileName;
  final int totalBytes;
  final int chunkSize;
  final int chunkCount;
  final String sha256Checksum;
  final String mimeType;
  final PayloadType payloadType;
  final Uint8List? extraMetadata;

  TransferMetadata({
    required this.transferId,
    required this.fileName,
    required this.totalBytes,
    this.chunkSize = defaultChunkSize,
    required this.sha256Checksum,
    this.mimeType = 'application/octet-stream',
    this.payloadType = PayloadType.file,
    this.extraMetadata,
  }) : chunkCount = calculateChunkCount(totalBytes, chunkSize) {
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'Cannot be negative');
    }
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be positive');
    }
  }

  static const int defaultChunkSize = 64 * 1024; // 64 KB default chunk

  /// Calculates the total number of chunks required for [totalBytes] with [chunkSize].
  static int calculateChunkCount(int totalBytes, int chunkSize) {
    if (totalBytes <= 0) {
      return 0;
    }
    if (chunkSize <= 0) {
      throw ArgumentError('chunkSize must be greater than zero');
    }
    return (totalBytes + chunkSize - 1) ~/ chunkSize;
  }

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'fileName': fileName,
    'totalBytes': totalBytes,
    'chunkSize': chunkSize,
    'chunkCount': chunkCount,
    'sha256Checksum': sha256Checksum,
    'mimeType': mimeType,
    'payloadType': payloadType.name,
    if (extraMetadata != null) 'extraMetadata': base64Encode(extraMetadata!),
  };

  factory TransferMetadata.fromJson(Map<String, dynamic> json) {
    PayloadType pType = PayloadType.file;
    if (json['payloadType'] != null) {
      try {
        pType = PayloadType.values.firstWhere(
          (t) => t.name == json['payloadType'],
        );
      } catch (_) {
        pType = PayloadType.file;
      }
    }
    Uint8List? extra;
    if (json['extraMetadata'] != null) {
      try {
        extra = base64Decode(json['extraMetadata'] as String);
      } catch (_) {}
    }

    return TransferMetadata(
      transferId: json['transferId'] as String,
      fileName: json['fileName'] as String,
      totalBytes: json['totalBytes'] as int,
      chunkSize: json['chunkSize'] as int? ?? defaultChunkSize,
      sha256Checksum: json['sha256Checksum'] as String,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      payloadType: pType,
      extraMetadata: extra,
    );
  }
}

/// Real-time progress update for an active transfer.
class TransferProgress {
  final String transferId;
  final int bytesTransferred;
  final int totalBytes;
  final int currentChunkIndex;
  final double speedBytesPerSecond;
  final int? etaSeconds;

  const TransferProgress({
    required this.transferId,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.currentChunkIndex,
    required this.speedBytesPerSecond,
    this.etaSeconds,
  });

  /// Progress fraction from 0.0 to 1.0.
  double get fraction =>
      totalBytes > 0 ? (bytesTransferred / totalBytes).clamp(0.0, 1.0) : 0.0;

  /// Progress percentage integer from 0 to 100.
  int get percentage => (fraction * 100).toInt();

  /// Whether the transfer has transferred all bytes.
  bool get isComplete => totalBytes > 0 && bytesTransferred >= totalBytes;
}
