import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/contracts/transfer_contract.dart';
import 'package:silosend_datasharing_app/domain/transfer/transfer_packet_payloads.dart';

void main() {
  group('Phase 7 Transfer Packet Payloads Tests', () {
    final sampleTransferId = Uint8List.fromList(
      List.generate(16, (i) => i + 1),
    );
    final sampleSha256 = Uint8List.fromList(
      List.generate(32, (i) => (i * 7) % 256),
    );

    group('TransferMetadataPayload', () {
      test('Serializes and deserializes accurately', () {
        final payload = TransferMetadataPayload(
          transferId: sampleTransferId,
          payloadType: PayloadType.file,
          totalBytes: 1024 * 1024 * 5, // 5 MB
          chunkSize: 64 * 1024,
          chunkCount: 80,
          sha256Hash: sampleSha256,
          fileName: 'confidential_report.pdf',
          mimeType: 'application/pdf',
          extraMetadata: Uint8List.fromList([0xAA, 0xBB, 0xCC]),
        );

        final wireBytes = payload.toBytes();
        expect(
          wireBytes.length,
          greaterThan(TransferMetadataPayload.minHeaderSize),
        );

        final decoded = TransferMetadataPayload.fromBytes(wireBytes);
        expect(decoded.transferId, equals(sampleTransferId));
        expect(decoded.payloadType, equals(PayloadType.file));
        expect(decoded.totalBytes, equals(1024 * 1024 * 5));
        expect(decoded.chunkSize, equals(64 * 1024));
        expect(decoded.chunkCount, equals(80));
        expect(decoded.sha256Hash, equals(sampleSha256));
        expect(decoded.fileName, equals('confidential_report.pdf'));
        expect(decoded.mimeType, equals('application/pdf'));
        expect(
          decoded.extraMetadata,
          equals(Uint8List.fromList([0xAA, 0xBB, 0xCC])),
        );
      });

      test('Sanitizes malicious path traversal file names', () {
        final payload = TransferMetadataPayload(
          transferId: sampleTransferId,
          payloadType: PayloadType.file,
          totalBytes: 100,
          chunkSize: 64,
          chunkCount: 2,
          sha256Hash: sampleSha256,
          fileName: '../../../../etc/passwd',
          mimeType: 'text/plain',
        );

        expect(payload.fileName, equals('passwd'));

        final winPayload = TransferMetadataPayload(
          transferId: sampleTransferId,
          payloadType: PayloadType.file,
          totalBytes: 100,
          chunkSize: 64,
          chunkCount: 2,
          sha256Hash: sampleSha256,
          fileName: r'C:\Windows\System32\drivers\etc\hosts',
          mimeType: 'text/plain',
        );
        expect(winPayload.fileName, equals('hosts'));
      });

      test('Rejects malformed, truncated, or out-of-bounds metadata', () {
        // Buffer too short
        expect(
          () => TransferMetadataPayload.fromBytes(Uint8List(30)),
          throwsFormatException,
        );

        // Invalid transferId length
        expect(
          () => TransferMetadataPayload(
            transferId: Uint8List(15),
            payloadType: PayloadType.file,
            totalBytes: 100,
            chunkSize: 64,
            chunkCount: 2,
            sha256Hash: sampleSha256,
            fileName: 'test.bin',
            mimeType: 'application/octet-stream',
          ),
          throwsArgumentError,
        );

        // Negative totalBytes
        expect(
          () => TransferMetadataPayload(
            transferId: sampleTransferId,
            payloadType: PayloadType.file,
            totalBytes: -1,
            chunkSize: 64,
            chunkCount: 2,
            sha256Hash: sampleSha256,
            fileName: 'test.bin',
            mimeType: 'application/octet-stream',
          ),
          throwsArgumentError,
        );
      });
    });

    group('TransferChunkPayload', () {
      test('Computes CRC32 and serializes/deserializes chunk cleanly', () {
        final chunkData = Uint8List.fromList(
          utf8.encode('Hello, SiloSend Transfer Engine!'),
        );
        final chunk = TransferChunkPayload.create(
          transferId: sampleTransferId,
          chunkIndex: 3,
          chunkOffset: 196608,
          chunkData: chunkData,
        );

        expect(chunk.chunkIndex, equals(3));
        expect(chunk.chunkOffset, equals(196608));
        expect(chunk.chunkLength, equals(chunkData.length));
        expect(chunk.verifyCrc(), isTrue);

        final wireBytes = chunk.toBytes();
        expect(
          wireBytes.length,
          equals(TransferChunkPayload.headerSize + chunkData.length),
        );

        final decoded = TransferChunkPayload.fromBytes(wireBytes);
        expect(decoded.transferId, equals(sampleTransferId));
        expect(decoded.chunkIndex, equals(3));
        expect(decoded.chunkOffset, equals(196608));
        expect(decoded.chunkLength, equals(chunkData.length));
        expect(decoded.chunkCrc32, equals(chunk.chunkCrc32));
        expect(decoded.chunkData, equals(chunkData));
        expect(decoded.verifyCrc(), isTrue);
      });

      test('Detects chunk corruption when bytes are modified', () {
        final chunkData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        final chunk = TransferChunkPayload.create(
          transferId: sampleTransferId,
          chunkIndex: 0,
          chunkOffset: 0,
          chunkData: chunkData,
        );

        expect(chunk.verifyCrc(), isTrue);

        // Tamper with one byte
        chunk.chunkData[3] ^= 0xFF;
        expect(chunk.verifyCrc(), isFalse);
      });

      test('Rejects malformed chunk wire payloads', () {
        expect(
          () => TransferChunkPayload.fromBytes(Uint8List(10)),
          throwsFormatException,
        );

        final validBytes = TransferChunkPayload.create(
          transferId: sampleTransferId,
          chunkIndex: 0,
          chunkOffset: 0,
          chunkData: Uint8List(16),
        ).toBytes();

        // Truncate by 1 byte
        expect(
          () => TransferChunkPayload.fromBytes(
            validBytes.sublist(0, validBytes.length - 1),
          ),
          throwsFormatException,
        );
      });
    });

    group('TransferAckPayload', () {
      test('Cumulative ACK serializes and validates bounds', () {
        final ack = TransferAckPayload.cumulative(
          transferId: sampleTransferId,
          ackType: TransferAckType.chunkReceived,
          highestContiguousChunkIndex: 12,
          bytesReceived: 851968,
        );

        expect(ack.isChunkAcknowledged(12), isTrue);
        expect(ack.isChunkAcknowledged(5), isTrue);
        expect(ack.isChunkAcknowledged(13), isFalse);

        final wireBytes = ack.toBytes();
        final decoded = TransferAckPayload.fromBytes(wireBytes);

        expect(decoded.transferId, equals(sampleTransferId));
        expect(decoded.ackType, equals(TransferAckType.chunkReceived));
        expect(decoded.highestContiguousChunkIndex, equals(12));
        expect(decoded.bytesReceived, equals(851968));
        expect(decoded.selectiveBitmap.isEmpty, isTrue);
        expect(decoded.isChunkAcknowledged(12), isTrue);
        expect(decoded.isChunkAcknowledged(13), isFalse);
      });

      test('Selective ACK (SACK) with bitmap lookahead operates correctly', () {
        // Highest contiguous is 5, but we also received chunks 7, 8, 10
        // Bitmap offset = 6
        // Chunk 6: bit 0 (diff 0) = 0 (missing)
        // Chunk 7: bit 1 (diff 1) = 1 (received)
        // Chunk 8: bit 2 (diff 2) = 1 (received)
        // Chunk 9: bit 3 (diff 3) = 0 (missing)
        // Chunk 10: bit 4 (diff 4) = 1 (received)
        final bitmap = Uint8List(1);
        bitmap[0] = (1 << 1) | (1 << 2) | (1 << 4); // 0x16

        final sack = TransferAckPayload(
          transferId: sampleTransferId,
          ackType: TransferAckType.chunkReceived,
          highestContiguousChunkIndex: 5,
          bytesReceived: 393216,
          selectiveBitmapOffset: 6,
          selectiveBitmap: bitmap,
        );

        // Contiguous check
        expect(sack.isChunkAcknowledged(5), isTrue);
        expect(sack.isChunkAcknowledged(4), isTrue);

        // Holes vs Selective
        expect(sack.isChunkAcknowledged(6), isFalse);
        expect(sack.isChunkAcknowledged(7), isTrue);
        expect(sack.isChunkAcknowledged(8), isTrue);
        expect(sack.isChunkAcknowledged(9), isFalse);
        expect(sack.isChunkAcknowledged(10), isTrue);
        expect(sack.isChunkAcknowledged(11), isFalse);

        final decoded = TransferAckPayload.fromBytes(sack.toBytes());
        expect(decoded.isChunkAcknowledged(5), isTrue);
        expect(decoded.isChunkAcknowledged(6), isFalse);
        expect(decoded.isChunkAcknowledged(7), isTrue);
        expect(decoded.isChunkAcknowledged(8), isTrue);
        expect(decoded.isChunkAcknowledged(9), isFalse);
        expect(decoded.isChunkAcknowledged(10), isTrue);
        expect(decoded.isChunkAcknowledged(11), isFalse);
      });
    });

    group('TransferNackPayload & TransferCancelPayload', () {
      test('NACK wire roundtrip', () {
        final nack = TransferNackPayload(
          transferId: sampleTransferId,
          chunkIndex: 4,
          reason: TransferNackReason.chunkCrcMismatch,
          details: 'CRC checksum failed on frame',
        );

        final decoded = TransferNackPayload.fromBytes(nack.toBytes());
        expect(decoded.transferId, equals(sampleTransferId));
        expect(decoded.chunkIndex, equals(4));
        expect(decoded.reason, equals(TransferNackReason.chunkCrcMismatch));
        expect(decoded.details, equals('CRC checksum failed on frame'));
      });

      test('Cancel wire roundtrip', () {
        final cancel = TransferCancelPayload(
          transferId: sampleTransferId,
          reason: TransferCancelReason.userCancelled,
          message: 'User aborted transfer in UI',
        );

        final decoded = TransferCancelPayload.fromBytes(cancel.toBytes());
        expect(decoded.transferId, equals(sampleTransferId));
        expect(decoded.reason, equals(TransferCancelReason.userCancelled));
        expect(decoded.message, equals('User aborted transfer in UI'));
      });
    });
  });
}
