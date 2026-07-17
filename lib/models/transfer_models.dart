import 'transport_models.dart';

enum TransferDirection { outgoing, incoming }

enum TransferStatus {
  queued,
  preparing,
  transferring,
  receiving,
  paused,
  verifying,
  completed,
  failed,
  canceled,
}

class TransferSourceFile {
  final String path;
  final String name;
  final int size;

  const TransferSourceFile({
    required this.path,
    required this.name,
    required this.size,
  });
}

class TransferItem {
  final String id;
  final TransferDirection direction;
  final TransferTransportMode transportMode;
  final String transportReason;
  final String peerId;
  final String peerName;
  final String fileName;
  final String? filePath;
  final String? savedPath;
  final int totalBytes;
  final int transferredBytes;
  final int chunkSize;
  final int chunkCount;
  final int currentChunkIndex;
  final TransferStatus status;
  final String checksum;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TransferItem({
    required this.id,
    required this.direction,
    required this.transportMode,
    required this.transportReason,
    required this.peerId,
    required this.peerName,
    required this.fileName,
    required this.totalBytes,
    required this.transferredBytes,
    required this.chunkSize,
    required this.chunkCount,
    required this.currentChunkIndex,
    required this.status,
    required this.checksum,
    required this.createdAt,
    required this.updatedAt,
    this.filePath,
    this.savedPath,
    this.errorMessage,
  });

  double get progress {
    if (totalBytes <= 0) return 0;
    return (transferredBytes / totalBytes).clamp(0.0, 1.0);
  }

  bool get isTerminal =>
      status == TransferStatus.completed ||
      status == TransferStatus.failed ||
      status == TransferStatus.canceled;

  bool get canPause => status == TransferStatus.transferring;

  bool get canResume => status == TransferStatus.paused;

  bool get canRetry =>
      status == TransferStatus.failed || status == TransferStatus.canceled;

  TransferItem copyWith({
    String? id,
    TransferDirection? direction,
    TransferTransportMode? transportMode,
    String? transportReason,
    String? peerId,
    String? peerName,
    String? fileName,
    String? filePath,
    String? savedPath,
    int? totalBytes,
    int? transferredBytes,
    int? chunkSize,
    int? chunkCount,
    int? currentChunkIndex,
    TransferStatus? status,
    String? checksum,
    String? errorMessage,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearError = false,
  }) {
    return TransferItem(
      id: id ?? this.id,
      direction: direction ?? this.direction,
      transportMode: transportMode ?? this.transportMode,
      transportReason: transportReason ?? this.transportReason,
      peerId: peerId ?? this.peerId,
      peerName: peerName ?? this.peerName,
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      savedPath: savedPath ?? this.savedPath,
      totalBytes: totalBytes ?? this.totalBytes,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      chunkSize: chunkSize ?? this.chunkSize,
      chunkCount: chunkCount ?? this.chunkCount,
      currentChunkIndex: currentChunkIndex ?? this.currentChunkIndex,
      status: status ?? this.status,
      checksum: checksum ?? this.checksum,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class TransferState {
  final List<TransferItem> items;
  final String? errorMessage;
  final String? activeTransferId;

  const TransferState({
    this.items = const [],
    this.errorMessage,
    this.activeTransferId,
  });

  TransferState copyWith({
    List<TransferItem>? items,
    String? errorMessage,
    String? activeTransferId,
    bool clearError = false,
  }) {
    return TransferState(
      items: items ?? this.items,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      activeTransferId: activeTransferId ?? this.activeTransferId,
    );
  }
}
