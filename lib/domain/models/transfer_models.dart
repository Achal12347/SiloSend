/// Metadata describing a transferable payload (file, contact, or data stream).
class TransferMetadata {
  final String transferId;
  final String fileName;
  final int totalBytes;
  final int chunkSize;
  final int chunkCount;
  final String sha256Checksum;
  final String mimeType;

  TransferMetadata({
    required this.transferId,
    required this.fileName,
    required this.totalBytes,
    this.chunkSize = defaultChunkSize,
    required this.sha256Checksum,
    this.mimeType = 'application/octet-stream',
  }) : chunkCount = calculateChunkCount(totalBytes, chunkSize);

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
  };

  factory TransferMetadata.fromJson(Map<String, dynamic> json) {
    return TransferMetadata(
      transferId: json['transferId'] as String,
      fileName: json['fileName'] as String,
      totalBytes: json['totalBytes'] as int,
      chunkSize: json['chunkSize'] as int? ?? defaultChunkSize,
      sha256Checksum: json['sha256Checksum'] as String,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
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
