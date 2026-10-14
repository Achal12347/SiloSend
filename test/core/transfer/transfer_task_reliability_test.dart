import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/transfer/payload_source.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

import 'transfer_task_test.dart' show TestSecureSession;

const _transferId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _local = '11111111111111111111111111111111';
const _remote = '22222222222222222222222222222222';
const _chunk = 64 * 1024;

/// Simulates the Android picker: every chunk read crosses an async platform hop.
class _SlowSource extends MemoryPayloadSource {
  _SlowSource(super.data);

  @override
  Future<Uint8List> readChunk(int offset, int length) async {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    return super.readChunk(offset, length);
  }
}

/// Session that acknowledges each chunk right after it is sent, like a fast receiver.
class _AutoAckSession extends TestSecureSession {
  OutboundTransferTask? task;
  final Set<int> outstanding = {};
  final Set<int> received = {};
  int maxOutstanding = 0;
  int contiguous = -1;

  @override
  Future<void> sendEncryptedPacket(VayuPacket packet) async {
    await super.sendEncryptedPacket(packet);
    if (packet.packetType != PacketType.transferChunk) return;
    final idx = TransferChunkPayload.fromBytes(packet.payload).chunkIndex;
    outstanding.add(idx);
    if (outstanding.length > maxOutstanding) {
      maxOutstanding = outstanding.length;
    }
    // Acknowledge on a later turn so several ACKs can race the sender's async reads.
    Timer(Duration.zero, () {
      outstanding.remove(idx);
      received.add(idx);
      while (received.contains(contiguous + 1)) {
        contiguous++;
      }
      task?.handleAck(
        TransferAckPayload.cumulative(
          transferId: parseIdTo16Bytes(_transferId),
          ackType: TransferAckType.chunkReceived,
          highestContiguousChunkIndex: contiguous,
          bytesReceived: (contiguous + 1) * _chunk,
        ),
      );
    });
  }
}

Future<TransferMetadata> _metadata(PayloadSource source, int totalBytes) async {
  return TransferMetadata(
    transferId: _transferId,
    fileName: 'large.bin',
    totalBytes: totalBytes,
    chunkSize: _chunk,
    sha256Checksum: await source.computeSha256(),
  );
}

TransferAckPayload _ack(TransferAckType type, int highest) =>
    TransferAckPayload.cumulative(
      transferId: parseIdTo16Bytes(_transferId),
      ackType: type,
      highestContiguousChunkIndex: highest,
      bytesReceived: highest < 0 ? 0 : (highest + 1) * _chunk,
    );

void main() {
  group('Outbound transfer reliability', () {
    test(
      'overlapping ACKs never push more chunks than the window allows',
      () async {
        const chunks = 60;
        final source = _SlowSource(Uint8List(_chunk * chunks));
        final session = _AutoAckSession();
        final task = OutboundTransferTask(
          transferId: _transferId,
          localDeviceId: _local,
          remoteDeviceId: _remote,
          secureSession: session,
          source: source,
          metadata: await _metadata(source, _chunk * chunks),
          windowSize: 8,
        );
        session.task = task;

        await task.start();
        task.handleAck(
          _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
        );

        while (session.contiguous < chunks - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(session.maxOutstanding, lessThanOrEqualTo(8));
        expect(task.status, TransferStatus.verifying);

        task.handleAck(_ack(TransferAckType.transferCompleted, chunks - 1));
        await task.done;
        expect(task.status, TransferStatus.completed);
      },
    );

    test(
      'a chunk rejected as beyond the receiver window is resent, not abandoned',
      () async {
        const chunks = 4;
        final source = MemoryPayloadSource(Uint8List(_chunk * chunks));
        final session = TestSecureSession();
        final task = OutboundTransferTask(
          transferId: _transferId,
          localDeviceId: _local,
          remoteDeviceId: _remote,
          secureSession: session,
          source: source,
          metadata: await _metadata(source, _chunk * chunks),
          windowSize: 2,
        );

        await task.start();
        task.handleAck(
          _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        int sendsOf(int idx) => session.sentPackets
            .where((p) => p.packetType == PacketType.transferChunk)
            .where(
              (p) =>
                  TransferChunkPayload.fromBytes(p.payload).chunkIndex == idx,
            )
            .length;
        expect(sendsOf(1), 1);

        await task.handleNack(
          TransferNackPayload(
            transferId: parseIdTo16Bytes(_transferId),
            chunkIndex: 1,
            reason: TransferNackReason.outOfOrderWindowExceeded,
            details: 'beyond horizon',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          sendsOf(1),
          2,
          reason: 'rejected chunk must be queued and resent',
        );
        expect(task.status, TransferStatus.transferring);
        await task.cancel();
      },
    );

    test(
      'sender waits for the receiver verification before reporting success',
      () async {
        final source = MemoryPayloadSource(Uint8List(_chunk));
        final session = TestSecureSession();
        final task = OutboundTransferTask(
          transferId: _transferId,
          localDeviceId: _local,
          remoteDeviceId: _remote,
          secureSession: session,
          source: source,
          metadata: await _metadata(source, _chunk),
        );

        await task.start();
        task.handleAck(
          _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        task.handleAck(_ack(TransferAckType.chunkReceived, 0));

        var finished = false;
        task.done.then((_) => finished = true).ignore();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(task.status, TransferStatus.verifying);
        expect(finished, isFalse);

        task.handleAck(_ack(TransferAckType.transferCompleted, 0));
        await task.done;
        expect(task.status, TransferStatus.completed);
      },
    );

    test(
      'missing receiver confirmation fails instead of claiming success',
      () async {
        final source = MemoryPayloadSource(Uint8List(_chunk));
        final session = TestSecureSession();
        final task = OutboundTransferTask(
          transferId: _transferId,
          localDeviceId: _local,
          remoteDeviceId: _remote,
          secureSession: session,
          source: source,
          metadata: await _metadata(source, _chunk),
          verificationTimeout: const Duration(milliseconds: 50),
        );

        await task.start();
        task.handleAck(
          _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        task.handleAck(_ack(TransferAckType.chunkReceived, 0));

        await expectLater(
          task.done,
          throwsA(isA<TransferVerificationTimeoutException>()),
        );
        expect(task.status, TransferStatus.failed);
      },
    );
  });
}
