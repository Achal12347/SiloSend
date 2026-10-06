import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/transfer/payload_destination.dart';
import 'package:vayu/domain/transfer/payload_source.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

class TestSecureSession implements SecureSession {
  @override
  final String sessionId;
  @override
  final String remoteDeviceId;
  @override
  SessionState state = SessionState.secured;

  final List<VayuPacket> sentPackets = [];
  final StreamController<VayuPacket> _incomingController =
      StreamController<VayuPacket>.broadcast();

  TestSecureSession({
    this.sessionId = '11111111111111111111111111111111',
    this.remoteDeviceId = '22222222222222222222222222222222',
  });

  @override
  bool get isEstablished => state == SessionState.secured;

  @override
  Stream<VayuPacket> get incomingDecryptedPackets =>
      _incomingController.stream;

  @override
  Future<void> sendEncryptedPacket(VayuPacket packet) async {
    sentPackets.add(packet);
  }

  void deliverPacket(VayuPacket packet) {
    _incomingController.add(packet);
  }

  @override
  Future<Uint8List> encryptPayload(
    Uint8List plaintext, {
    Uint8List? associatedData,
  }) async => plaintext;

  @override
  Future<Uint8List> decryptPayload(
    Uint8List ciphertext, {
    Uint8List? associatedData,
  }) async => ciphertext;

  @override
  Future<void> terminate() async {
    state = SessionState.closed;
    await _incomingController.close();
  }
}

void main() {
  group('Phase 7 TransferTask Sliding Window & Integrity Tests', () {
    const transferIdStr = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const localDeviceStr = '11111111111111111111111111111111';
    const remoteDeviceStr = '22222222222222222222222222222222';
    final transferIdBytes = parseIdTo16Bytes(transferIdStr);

    test('OutboundTransferTask throttles in-flight chunks to sliding window size (W=8)', () async {
      final session = TestSecureSession();
      final totalBytes = 64 * 1024 * 20; // 20 chunks of 64KB
      final rawData = Uint8List(totalBytes);
      final source = MemoryPayloadSource(rawData);
      final sha = await source.computeSha256();

      final metadata = TransferMetadata(
        transferId: transferIdStr,
        fileName: 'big_archive.zip',
        totalBytes: totalBytes,
        chunkSize: 64 * 1024,
        sha256Checksum: sha,
      );

      final task = OutboundTransferTask(
        transferId: transferIdStr,
        localDeviceId: localDeviceStr,
        remoteDeviceId: remoteDeviceStr,
        secureSession: session,
        source: source,
        metadata: metadata,
        windowSize: 8,
      );

      await task.start();

      // 1. Initial metadata packet sent
      expect(session.sentPackets.length, equals(1));
      expect(
        session.sentPackets.first.packetType,
        equals(PacketType.transferMetadata),
      );

      // 2. Peer accepts offer
      task.handleAck(
        TransferAckPayload.cumulative(
          transferId: transferIdBytes,
          ackType: TransferAckType.offerAccepted,
          highestContiguousChunkIndex: TransferAckPayload.noneAcked,
          bytesReceived: 0,
        ),
      );

      // Give event loop time to process async reads
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Window size is 8, so exactly 8 chunk packets should have been sent (indices 0..7)
      final chunkPackets = session.sentPackets
          .where((p) => p.packetType == PacketType.transferChunk)
          .toList();
      expect(chunkPackets.length, equals(8));

      // Verify chunk indices 0 to 7
      for (int i = 0; i < 8; i++) {
        final chunk = TransferChunkPayload.fromBytes(chunkPackets[i].payload);
        expect(chunk.chunkIndex, equals(i));
      }

      // 3. Peer ACKs chunk 0 -> Sliding window advances and sends chunk 8
      task.handleAck(
        TransferAckPayload.cumulative(
          transferId: transferIdBytes,
          ackType: TransferAckType.chunkReceived,
          highestContiguousChunkIndex: 0,
          bytesReceived: 64 * 1024,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final chunkPacketsAfterAck = session.sentPackets
          .where((p) => p.packetType == PacketType.transferChunk)
          .toList();
      expect(chunkPacketsAfterAck.length, equals(9));
      final chunk8 = TransferChunkPayload.fromBytes(
        chunkPacketsAfterAck[8].payload,
      );
      expect(chunk8.chunkIndex, equals(8));

      await task.cancel();
    });

    test(
      'OutboundTransferTask performs fast-retransmit upon receiving CRC NACK',
      () async {
        final session = TestSecureSession();
        final totalBytes = 64 * 1024 * 2;
        final rawData = Uint8List(totalBytes);
        final source = MemoryPayloadSource(rawData);
        final sha = await source.computeSha256();

        final metadata = TransferMetadata(
          transferId: transferIdStr,
          fileName: 'file.bin',
          totalBytes: totalBytes,
          chunkSize: 64 * 1024,
          sha256Checksum: sha,
        );

        final task = OutboundTransferTask(
          transferId: transferIdStr,
          localDeviceId: localDeviceStr,
          remoteDeviceId: remoteDeviceStr,
          secureSession: session,
          source: source,
          metadata: metadata,
        );

        await task.start();
        task.handleAck(
          TransferAckPayload.cumulative(
            transferId: transferIdBytes,
            ackType: TransferAckType.offerAccepted,
            highestContiguousChunkIndex: TransferAckPayload.noneAcked,
            bytesReceived: 0,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final initialChunks = session.sentPackets
            .where((p) => p.packetType == PacketType.transferChunk)
            .length;
        expect(initialChunks, equals(2));

        // Peer reports CRC error on chunk 0
        await task.handleNack(
          TransferNackPayload(
            transferId: transferIdBytes,
            chunkIndex: 0,
            reason: TransferNackReason.chunkCrcMismatch,
            details: 'CRC failed',
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        final totalChunksSent = session.sentPackets
            .where((p) => p.packetType == PacketType.transferChunk)
            .toList();
        // Chunk 0 resent
        expect(totalChunksSent.length, equals(3));
        final resentChunk = TransferChunkPayload.fromBytes(
          totalChunksSent.last.payload,
        );
        expect(resentChunk.chunkIndex, equals(0));

        await task.cancel();
      },
    );

    test(
      'OutboundTransferTask retries on timeout and fails if retries exhausted',
      () async {
        final session = TestSecureSession();
        final totalBytes = 64 * 1024;
        final rawData = Uint8List(totalBytes);
        final source = MemoryPayloadSource(rawData);
        final sha = await source.computeSha256();

        final metadata = TransferMetadata(
          transferId: transferIdStr,
          fileName: 'file.bin',
          totalBytes: totalBytes,
          chunkSize: 64 * 1024,
          sha256Checksum: sha,
        );

        final task = OutboundTransferTask(
          transferId: transferIdStr,
          localDeviceId: localDeviceStr,
          remoteDeviceId: remoteDeviceStr,
          secureSession: session,
          source: source,
          metadata: metadata,
          chunkTimeout: const Duration(milliseconds: 30),
          maxRetries: 2,
        );

        await task.start();
        task.handleAck(
          TransferAckPayload.cumulative(
            transferId: transferIdBytes,
            ackType: TransferAckType.offerAccepted,
            highestContiguousChunkIndex: TransferAckPayload.noneAcked,
            bytesReceived: 0,
          ),
        );

        // Wait for 2 retries to exhaust (30ms * 3 > 90ms)
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(task.status, equals(TransferStatus.failed));
        expect(task.done, throwsA(isA<TransferTimeoutException>()));
      },
    );

    test('InboundTransferTask handles out-of-order chunks and produces accurate SACKs', () async {
      final session = TestSecureSession();
      final totalBytes = 64 * 1024 * 3; // 3 chunks
      final rawData = Uint8List.fromList(
        List.generate(totalBytes, (i) => (i * 5) % 256),
      );
      final memSource = MemoryPayloadSource(rawData);
      final sha = await memSource.computeSha256();

      final destination = MemoryPayloadDestination(totalBytes: totalBytes);
      final metadata = TransferMetadata(
        transferId: transferIdStr,
        fileName: 'out_of_order.bin',
        totalBytes: totalBytes,
        chunkSize: 64 * 1024,
        sha256Checksum: sha,
      );

      final task = InboundTransferTask(
        transferId: transferIdStr,
        localDeviceId: localDeviceStr,
        remoteDeviceId: remoteDeviceStr,
        secureSession: session,
        destination: destination,
        metadata: metadata,
      );

      // Deliver Chunk 0
      final chunk0Data = rawData.sublist(0, 64 * 1024);
      final chunk0 = TransferChunkPayload.create(
        transferId: transferIdBytes,
        chunkIndex: 0,
        chunkOffset: 0,
        chunkData: chunk0Data,
      );
      await task.handleChunk(chunk0);

      expect(session.sentPackets.length, equals(1));
      final ack0 = TransferAckPayload.fromBytes(
        session.sentPackets.last.payload,
      );
      expect(ack0.highestContiguousChunkIndex, equals(0));

      // Deliver Chunk 2 (leaving gap at Chunk 1)
      final chunk2Data = rawData.sublist(128 * 1024, totalBytes);
      final chunk2 = TransferChunkPayload.create(
        transferId: transferIdBytes,
        chunkIndex: 2,
        chunkOffset: 128 * 1024,
        chunkData: chunk2Data,
      );
      await task.handleChunk(chunk2);

      expect(session.sentPackets.length, equals(2));
      final ack1 = TransferAckPayload.fromBytes(
        session.sentPackets.last.payload,
      );
      // Contiguous is still 0
      expect(ack1.highestContiguousChunkIndex, equals(0));
      // Chunk 2 is selectively acknowledged
      expect(ack1.isChunkAcknowledged(2), isTrue);
      // Chunk 1 is not acknowledged
      expect(ack1.isChunkAcknowledged(1), isFalse);

      // Now deliver missing Chunk 1
      final chunk1Data = rawData.sublist(64 * 1024, 128 * 1024);
      final chunk1 = TransferChunkPayload.create(
        transferId: transferIdBytes,
        chunkIndex: 1,
        chunkOffset: 64 * 1024,
        chunkData: chunk1Data,
      );
      await task.handleChunk(chunk1);

      // All chunks received and verified!
      expect(task.status, equals(TransferStatus.completed));
      expect(destination.buffer, equals(rawData));

      // Last packet was TransferAckType.transferCompleted
      final finalAck = TransferAckPayload.fromBytes(
        session.sentPackets.last.payload,
      );
      expect(finalAck.ackType, equals(TransferAckType.transferCompleted));
    });

    test('InboundTransferTask rejects tampered chunks with CRC NACK', () async {
      final session = TestSecureSession();
      final totalBytes = 64 * 1024;
      final rawData = Uint8List(totalBytes);
      final destination = MemoryPayloadDestination(totalBytes: totalBytes);
      final metadata = TransferMetadata(
        transferId: transferIdStr,
        fileName: 'corrupt.bin',
        totalBytes: totalBytes,
        chunkSize: 64 * 1024,
        sha256Checksum:
            '0000000000000000000000000000000000000000000000000000000000000000',
      );

      final task = InboundTransferTask(
        transferId: transferIdStr,
        localDeviceId: localDeviceStr,
        remoteDeviceId: remoteDeviceStr,
        secureSession: session,
        destination: destination,
        metadata: metadata,
      );

      // Create corrupted chunk
      final corruptedChunk = TransferChunkPayload(
        transferId: transferIdBytes,
        chunkIndex: 0,
        chunkOffset: 0,
        chunkLength: 64 * 1024,
        chunkCrc32: 0x12345678, // Invalid CRC
        chunkData: rawData,
      );

      await task.handleChunk(corruptedChunk);

      expect(session.sentPackets.length, equals(1));
      expect(
        session.sentPackets.first.packetType,
        equals(PacketType.transferNack),
      );

      final nack = TransferNackPayload.fromBytes(
        session.sentPackets.first.payload,
      );
      expect(nack.chunkIndex, equals(0));
      expect(nack.reason, equals(TransferNackReason.chunkCrcMismatch));
    });

    test('InboundTransferTask detects full payload SHA-256 mismatch and aborts', () async {
      final session = TestSecureSession();
      final totalBytes = 64 * 1024;
      final rawData = Uint8List(totalBytes);
      final destination = MemoryPayloadDestination(totalBytes: totalBytes);

      // Expectation does not match rawData hash
      final metadata = TransferMetadata(
        transferId: transferIdStr,
        fileName: 'mismatch.bin',
        totalBytes: totalBytes,
        chunkSize: 64 * 1024,
        sha256Checksum:
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      );

      final task = InboundTransferTask(
        transferId: transferIdStr,
        localDeviceId: localDeviceStr,
        remoteDeviceId: remoteDeviceStr,
        secureSession: session,
        destination: destination,
        metadata: metadata,
      );

      final chunk0 = TransferChunkPayload.create(
        transferId: transferIdBytes,
        chunkIndex: 0,
        chunkOffset: 0,
        chunkData: rawData,
      );

      await task.handleChunk(chunk0);

      expect(task.status, equals(TransferStatus.failed));
      expect(task.done, throwsA(isA<TransferChecksumMismatchException>()));

      // Verified cancel packet sent
      final cancelPacket = session.sentPackets.firstWhere(
        (p) => p.packetType == PacketType.transferCancel,
      );
      final cancelPayload = TransferCancelPayload.fromBytes(
        cancelPacket.payload,
      );
      expect(
        cancelPayload.reason,
        equals(TransferCancelReason.checksumMismatch),
      );
    });

    test(
      'OutboundTransferTask fails truthfully when secure session closes',
      () async {
        final session = TestSecureSession();
        final source = MemoryPayloadSource(Uint8List(64 * 1024));
        final metadata = TransferMetadata(
          transferId: transferIdStr,
          fileName: 'interrupted.bin',
          totalBytes: source.length,
          chunkSize: 64 * 1024,
          sha256Checksum: await source.computeSha256(),
        );
        final task = OutboundTransferTask(
          transferId: transferIdStr,
          localDeviceId: localDeviceStr,
          remoteDeviceId: remoteDeviceStr,
          secureSession: session,
          source: source,
          metadata: metadata,
        );

        await task.start();
        task.handleSessionClosed('Wi-Fi connection lost');

        expect(task.status, TransferStatus.failed);
        expect(task.done, throwsA(isA<TransferConnectionException>()));
      },
    );

    test(
      'InboundTransferTask removes staging data when secure session closes',
      () async {
        final session = TestSecureSession();
        final tempDir = await Directory.systemTemp.createTemp(
          'vayu_interrupt_',
        );
        final targetPath = '${tempDir.path}/interrupted.bin';
        final destination = FilePayloadDestination(
          targetFilePath: targetPath,
          totalBytes: 128 * 1024,
        );
        final task = InboundTransferTask(
          transferId: transferIdStr,
          localDeviceId: localDeviceStr,
          remoteDeviceId: remoteDeviceStr,
          secureSession: session,
          destination: destination,
          metadata: TransferMetadata(
            transferId: transferIdStr,
            fileName: 'interrupted.bin',
            totalBytes: 128 * 1024,
            chunkSize: 64 * 1024,
            sha256Checksum: '0' * 64,
          ),
        );

        await task.handleChunk(
          TransferChunkPayload.create(
            transferId: transferIdBytes,
            chunkIndex: 0,
            chunkOffset: 0,
            chunkData: Uint8List(64 * 1024),
          ),
        );
        await task.handleSessionClosed('LAN connection lost');

        expect(task.status, TransferStatus.failed);
        expect(task.done, throwsA(isA<TransferConnectionException>()));
        expect(File(destination.stagingPath).existsSync(), isFalse);
        expect(File(targetPath).existsSync(), isFalse);

        await tempDir.delete(recursive: true);
      },
    );
  });
}
