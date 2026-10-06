import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/domain/models/transfer_models.dart';

void main() {
  group('TransferMetadata Tests', () {
    test('calculates correct chunk counts for various file sizes', () {
      const chunkSize = 64 * 1024; // 64 KB

      // 0 bytes
      expect(TransferMetadata.calculateChunkCount(0, chunkSize), equals(0));

      // 1 byte -> 1 chunk
      expect(TransferMetadata.calculateChunkCount(1, chunkSize), equals(1));

      // Exactly 64 KB -> 1 chunk
      expect(
        TransferMetadata.calculateChunkCount(chunkSize, chunkSize),
        equals(1),
      );

      // 64 KB + 1 byte -> 2 chunks
      expect(
        TransferMetadata.calculateChunkCount(chunkSize + 1, chunkSize),
        equals(2),
      );

      // 1 MB -> 16 chunks
      expect(
        TransferMetadata.calculateChunkCount(1024 * 1024, chunkSize),
        equals(16),
      );
    });

    test('serializes to and from JSON correctly', () {
      final metadata = TransferMetadata(
        transferId: 'transfer-123',
        fileName: 'sample_video.mp4',
        totalBytes: 500000,
        chunkSize: 64 * 1024,
        sha256Checksum: 'abcdef1234567890',
        mimeType: 'video/mp4',
      );

      final json = metadata.toJson();
      final restored = TransferMetadata.fromJson(json);

      expect(restored.transferId, equals('transfer-123'));
      expect(restored.fileName, equals('sample_video.mp4'));
      expect(restored.totalBytes, equals(500000));
      expect(restored.chunkSize, equals(64 * 1024));
      expect(restored.chunkCount, equals(8));
      expect(restored.sha256Checksum, equals('abcdef1234567890'));
      expect(restored.mimeType, equals('video/mp4'));
    });
  });

  group('TransferProgress Tests', () {
    test('computes fraction, percentage, and completion status', () {
      const progress = TransferProgress(
        transferId: 'transfer-123',
        bytesTransferred: 500,
        totalBytes: 1000,
        currentChunkIndex: 0,
        speedBytesPerSecond: 250000,
        etaSeconds: 2,
      );

      expect(progress.fraction, equals(0.5));
      expect(progress.percentage, equals(50));
      expect(progress.isComplete, isFalse);

      const completedProgress = TransferProgress(
        transferId: 'transfer-123',
        bytesTransferred: 1000,
        totalBytes: 1000,
        currentChunkIndex: 1,
        speedBytesPerSecond: 300000,
        etaSeconds: 0,
      );

      expect(completedProgress.fraction, equals(1.0));
      expect(completedProgress.percentage, equals(100));
      expect(completedProgress.isComplete, isTrue);
    });

    test('handles zero totalBytes safely', () {
      const emptyProgress = TransferProgress(
        transferId: 'transfer-0',
        bytesTransferred: 0,
        totalBytes: 0,
        currentChunkIndex: 0,
        speedBytesPerSecond: 0,
      );

      expect(emptyProgress.fraction, equals(0.0));
      expect(emptyProgress.percentage, equals(0));
      expect(emptyProgress.isComplete, isFalse);
    });
  });
}
