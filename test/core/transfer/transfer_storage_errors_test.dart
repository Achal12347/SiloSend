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

import 'transfer_task_test.dart' show TestSecureSession;

const _transferId = 'cccccccccccccccccccccccccccccccc';
const _local = '11111111111111111111111111111111';
const _remote = '22222222222222222222222222222222';
const _chunk = 64 * 1024;

/// Fails the first send of one chunk, the way a brief Wi-Fi drop does.
class _FlakySendSession extends TestSecureSession {
  final int failChunk;
  bool failed = false;
  _FlakySendSession(this.failChunk);

  @override
  Future<void> sendEncryptedPacket(VayuPacket packet) async {
    if (!failed && packet.packetType == PacketType.transferChunk) {
      final idx = TransferChunkPayload.fromBytes(packet.payload).chunkIndex;
      if (idx == failChunk) {
        failed = true;
        throw const SocketException('Broken pipe');
      }
    }
    await super.sendEncryptedPacket(packet);
  }
}

class _CountingSource extends MemoryPayloadSource {
  final List<int> reads = [];
  _CountingSource(super.data);

  @override
  Future<Uint8List> readChunk(int offset, int length) async {
    reads.add(offset ~/ _chunk);
    return super.readChunk(offset, length);
  }
}

class _FailingSource extends MemoryPayloadSource {
  _FailingSource(super.data);

  @override
  Future<Uint8List> readChunk(int offset, int length) async {
    throw const FileSystemException('File was deleted');
  }
}

/// Destination whose writes fail with a chosen error.
class _ThrowingDestination implements PayloadDestination {
  final Object error;
  _ThrowingDestination(this.error);

  @override
  int get totalBytes => _chunk;
  @override
  Future<void> writeChunk(int offset, Uint8List data) async => throw error;
  @override
  Future<String> computeSha256() async => '';
  @override
  Future<void> finalize() async {}
  @override
  Future<void> abortAndCleanup() async {}
  @override
  Future<void> close() async {}
}

Uint8List _data(int bytes) =>
    Uint8List.fromList(List<int>.generate(bytes, (i) => i % 251));

Future<TransferMetadata> _metadata(PayloadSource source) async =>
    TransferMetadata(
      transferId: _transferId,
      fileName: 'file.bin',
      totalBytes: source.length,
      chunkSize: _chunk,
      sha256Checksum: await source.computeSha256(),
    );

TransferAckPayload _ack(TransferAckType type, int highest) =>
    TransferAckPayload.cumulative(
      transferId: parseIdTo16Bytes(_transferId),
      ackType: type,
      highestContiguousChunkIndex: highest,
      bytesReceived: highest < 0 ? 0 : (highest + 1) * _chunk,
    );

TransferChunkPayload _chunkOf(Uint8List data, int index) {
  final start = index * _chunk;
  final end = (start + _chunk).clamp(0, data.length);
  return TransferChunkPayload.create(
    transferId: parseIdTo16Bytes(_transferId),
    chunkIndex: index,
    chunkOffset: start,
    chunkData: data.sublist(start, end),
  );
}

List<TransferAckPayload> _acksSent(TestSecureSession s) => s.sentPackets
    .where((p) => p.packetType == PacketType.transferAck)
    .map((p) => TransferAckPayload.fromBytes(p.payload))
    .toList();

void main() {
  group('Sender error classification', () {
    test('a failed chunk send is retried, not reported as storage', () async {
      final source = MemoryPayloadSource(_data(_chunk * 3));
      final session = _FlakySendSession(1);
      final task = OutboundTransferTask(
        transferId: _transferId,
        localDeviceId: _local,
        remoteDeviceId: _remote,
        secureSession: session,
        source: source,
        metadata: await _metadata(source),
        chunkTimeout: const Duration(milliseconds: 40),
      );

      await task.start();
      task.handleAck(
        _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
      );
      // Chunk 1's first send failed; its timer must resend it.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final sentChunk1 = session.sentPackets.where(
        (p) =>
            p.packetType == PacketType.transferChunk &&
            TransferChunkPayload.fromBytes(p.payload).chunkIndex == 1,
      );
      expect(session.failed, isTrue);
      expect(sentChunk1, isNotEmpty);
      expect(task.status, TransferStatus.transferring);

      task.handleAck(_ack(TransferAckType.chunkReceived, 2));
      task.handleAck(_ack(TransferAckType.transferCompleted, 2));
      await task.done;
      expect(task.status, TransferStatus.completed);
    });

    test('a send failure on a closed session is a connection error', () async {
      final source = MemoryPayloadSource(_data(_chunk * 2));
      final session = _FlakySendSession(0);
      final task = OutboundTransferTask(
        transferId: _transferId,
        localDeviceId: _local,
        remoteDeviceId: _remote,
        secureSession: session,
        source: source,
        metadata: await _metadata(source),
      );
      await task.start();
      session.state = SessionState.closed;
      task.handleAck(
        _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
      );
      await expectLater(task.done, throwsA(isA<TransferConnectionException>()));
    });

    test(
      'an unreadable source fails as a source error and tells the receiver',
      () async {
        final source = _FailingSource(_data(_chunk));
        final session = TestSecureSession();
        final task = OutboundTransferTask(
          transferId: _transferId,
          localDeviceId: _local,
          remoteDeviceId: _remote,
          secureSession: session,
          source: source,
          metadata: TransferMetadata(
            transferId: _transferId,
            fileName: 'file.bin',
            totalBytes: _chunk,
            chunkSize: _chunk,
            sha256Checksum: '0' * 64,
          ),
        );
        await task.start();
        task.handleAck(
          _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
        );
        await expectLater(task.done, throwsA(isA<TransferSourceException>()));
        await Future<void>.delayed(Duration.zero);
        final cancel = session.sentPackets.lastWhere(
          (p) => p.packetType == PacketType.transferCancel,
        );
        expect(
          TransferCancelPayload.fromBytes(cancel.payload).reason,
          TransferCancelReason.sourceUnreadable,
        );
      },
    );

    for (final entry in {
      TransferNackReason.storageFull: true,
      TransferNackReason.ioError: false,
    }.entries) {
      test('NACK ${entry.key.name} sets outOfSpace=${entry.value}', () async {
        final source = MemoryPayloadSource(_data(_chunk * 2));
        final task = OutboundTransferTask(
          transferId: _transferId,
          localDeviceId: _local,
          remoteDeviceId: _remote,
          secureSession: TestSecureSession(),
          source: source,
          metadata: await _metadata(source),
        );
        await task.start();
        task.handleAck(
          _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
        );
        await task.handleNack(
          TransferNackPayload(
            transferId: parseIdTo16Bytes(_transferId),
            chunkIndex: 0,
            reason: entry.key,
            details: 'x',
          ),
        );
        await expectLater(
          task.done,
          throwsA(
            isA<TransferStorageException>().having(
              (e) => e.outOfSpace,
              'outOfSpace',
              entry.value,
            ),
          ),
        );
      });
    }
  });

  group('Receiver chunk handling', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('vayu_rx_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('last chunks arriving together finalize exactly once', () async {
      final data = _data(_chunk * 4 + 100);
      final source = MemoryPayloadSource(data);
      final session = TestSecureSession();
      final target = '${dir.path}/out.bin';
      final task = InboundTransferTask(
        transferId: _transferId,
        localDeviceId: _local,
        remoteDeviceId: _remote,
        secureSession: session,
        destination: FilePayloadDestination(
          targetFilePath: target,
          totalBytes: data.length,
        ),
        metadata: await _metadata(source),
      );

      // Not awaited, exactly as the engine dispatches them.
      final pending = [
        for (var i = 0; i < 5; i++) task.handleChunk(_chunkOf(data, i)),
      ];
      await Future.wait(pending);
      await task.done;

      expect(task.status, TransferStatus.completed);
      expect(File(target).readAsBytesSync(), data);
      final completions = _acksSent(session)
          .where((a) => a.ackType == TransferAckType.transferCompleted);
      expect(completions, hasLength(1));
    });

    test('a duplicate chunk racing its original is counted once', () async {
      final data = _data(_chunk * 2);
      final source = MemoryPayloadSource(data);
      final task = InboundTransferTask(
        transferId: _transferId,
        localDeviceId: _local,
        remoteDeviceId: _remote,
        secureSession: TestSecureSession(),
        destination: FilePayloadDestination(
          targetFilePath: '${dir.path}/dup.bin',
          totalBytes: data.length,
        ),
        metadata: await _metadata(source),
      );

      await Future.wait([
        task.handleChunk(_chunkOf(data, 0)),
        task.handleChunk(_chunkOf(data, 0)),
        task.handleChunk(_chunkOf(data, 1)),
      ]);
      await task.done;
      expect(task.lastProgress!.bytesTransferred, data.length);
    });

    for (final entry in {
      'disk full': (
        const FileSystemException('write', 'x', OSError('No space', 28)),
        TransferNackReason.storageFull,
        true,
      ),
      'other I/O error': (
        const FileSystemException('write', 'x', OSError('EIO', 5)),
        TransferNackReason.ioError,
        false,
      ),
    }.entries) {
      test('${entry.key} is reported as ${entry.value.$2.name}', () async {
        final session = TestSecureSession();
        final task = InboundTransferTask(
          transferId: _transferId,
          localDeviceId: _local,
          remoteDeviceId: _remote,
          secureSession: session,
          destination: _ThrowingDestination(entry.value.$1),
          metadata: TransferMetadata(
            transferId: _transferId,
            fileName: 'file.bin',
            totalBytes: _chunk,
            chunkSize: _chunk,
            sha256Checksum: '0' * 64,
          ),
        );
        await task.handleChunk(_chunkOf(_data(_chunk), 0));
        await expectLater(
          task.done,
          throwsA(
            isA<TransferStorageException>().having(
              (e) => e.outOfSpace,
              'outOfSpace',
              entry.value.$3,
            ),
          ),
        );
        final nack = session.sentPackets.firstWhere(
          (p) => p.packetType == PacketType.transferNack,
        );
        expect(
          TransferNackPayload.fromBytes(nack.payload).reason,
          entry.value.$2,
        );
      });
    }
  });

  group('Receiver ACK batching', () {
    InboundTransferTask task(TestSecureSession session, Uint8List data) =>
        InboundTransferTask(
          transferId: _transferId,
          localDeviceId: _local,
          remoteDeviceId: _remote,
          secureSession: session,
          destination: MemoryPayloadDestination(totalBytes: data.length),
          metadata: TransferMetadata(
            transferId: _transferId,
            fileName: 'file.bin',
            totalBytes: data.length,
            chunkSize: _chunk,
            sha256Checksum: '0' * 64,
          ),
          ackDelay: const Duration(milliseconds: 30),
        );

    test('two in-order chunks share one ACK', () async {
      final data = _data(_chunk * 4);
      final session = TestSecureSession();
      final rx = task(session, data);
      await rx.handleChunk(_chunkOf(data, 0));
      expect(_acksSent(session), isEmpty);
      await rx.handleChunk(_chunkOf(data, 1));
      await Future<void>.delayed(Duration.zero);
      final acks = _acksSent(session);
      expect(acks, hasLength(1));
      expect(acks.single.highestContiguousChunkIndex, 1);
    });

    test('a lone chunk is acknowledged after the short delay', () async {
      final data = _data(_chunk * 4);
      final session = TestSecureSession();
      final rx = task(session, data);
      await rx.handleChunk(_chunkOf(data, 0));
      expect(_acksSent(session), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(_acksSent(session), hasLength(1));
    });

    test('a gap is reported at once so the sender can resend', () async {
      final data = _data(_chunk * 4);
      final session = TestSecureSession();
      final rx = task(session, data);
      await rx.handleChunk(_chunkOf(data, 2));
      await Future<void>.delayed(Duration.zero);
      final acks = _acksSent(session);
      expect(acks, hasLength(1));
      expect(acks.single.isChunkAcknowledged(2), isTrue);
      expect(acks.single.isChunkAcknowledged(0), isFalse);
    });
  });

  group('Sender read-ahead', () {
    test('reads run ahead of sends and every chunk is read once', () async {
      final data = _data(_chunk * 6);
      final source = _CountingSource(data);
      final session = TestSecureSession();
      final tx = OutboundTransferTask(
        transferId: _transferId,
        localDeviceId: _local,
        remoteDeviceId: _remote,
        secureSession: session,
        source: source,
        metadata: await _metadata(MemoryPayloadSource(data)),
        windowSize: 2,
      );
      await tx.start();
      tx.handleAck(
        _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Window of 2 sent, plus up to 2 more read ahead.
      expect(source.reads.toSet(), containsAll([0, 1, 2]));
      for (var i = 0; i < 6; i++) {
        tx.handleAck(_ack(TransferAckType.chunkReceived, i));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      tx.handleAck(_ack(TransferAckType.transferCompleted, 5));
      await tx.done;
      expect(source.reads..sort(), [0, 1, 2, 3, 4, 5]);
    });
  });

  test('isOutOfSpaceError recognises ENOSPC only', () {
    expect(
      isOutOfSpaceError(
        const FileSystemException('w', 'p', OSError('No space', 28)),
      ),
      isTrue,
    );
    expect(
      isOutOfSpaceError(const FileSystemException('w', 'p', OSError('', 13))),
      isFalse,
    );
    expect(isOutOfSpaceError(StateError('x')), isFalse);
  });
}
