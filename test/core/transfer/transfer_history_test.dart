import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

TransferHistoryRecord _record(
  String id, {
  DateTime? at,
  TransferOutcome outcome = TransferOutcome.completed,
  String? kind,
}) => TransferHistoryRecord(
  transferId: id,
  batchId: 'b1',
  outbound: false,
  peerDeviceId: 'aa' * 16,
  peerName: 'Vayu-BlueFalcon-7K',
  fileName: '$id.jpg',
  sizeBytes: 1234,
  mimeType: 'image/jpeg',
  outcome: outcome,
  failureKind: kind,
  finishedAt: at ?? DateTime(2026, 10, 14, 10),
  savedPath: '/storage/Download/Vayu/$id.jpg',
);

void main() {
  test('the route survives saving', () {
    final record = TransferHistoryRecord(
      transferId: 't',
      outbound: true,
      peerDeviceId: 'p',
      peerName: 'Bo',
      fileName: 'a.bin',
      sizeBytes: 1,
      mimeType: 'application/octet-stream',
      outcome: TransferOutcome.completed,
      finishedAt: DateTime(2026),
      route: 'wifiDirect',
    );
    expect(
      TransferHistoryRecord.tryFromJson(record.toJson())?.route,
      'wifiDirect',
    );
  });

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('vayu_history_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('history survives a restart', () async {
    final file = File('${dir.path}/transfer_history.json');
    final first = TransferHistory(FileTransferHistoryStorage(file));
    await first.load();
    await first.add(_record('one', at: DateTime(2026, 10, 14, 9)));
    await first.add(
      _record(
        'two',
        at: DateTime(2026, 10, 14, 10),
        outcome: TransferOutcome.failed,
        kind: TransferFailureKind.outOfSpace.name,
      ),
    );

    final second = TransferHistory(FileTransferHistoryStorage(file));
    await second.load();
    expect(second.records.map((r) => r.transferId), ['two', 'one']);
    final failed = second.records.first;
    expect(failed.outcome, TransferOutcome.failed);
    expect(failed.failureKind, 'outOfSpace');
    expect(failed.peerName, 'Vayu-BlueFalcon-7K');
    expect(second.records.last.savedPath, '/storage/Download/Vayu/one.jpg');
  });

  test('a damaged history file loads as empty instead of crashing', () async {
    final file = File('${dir.path}/transfer_history.json')
      ..writeAsStringSync('{not json');
    final history = TransferHistory(FileTransferHistoryStorage(file));
    await history.load();
    expect(history.records, isEmpty);
  });

  test('history is capped and keeps the newest', () async {
    final history = TransferHistory(InMemoryTransferHistoryStorage());
    for (var i = 0; i < TransferHistory.capacity + 5; i++) {
      await history.add(_record('t$i'));
    }
    expect(history.records, hasLength(TransferHistory.capacity));
    expect(
      history.records.first.transferId,
      't${TransferHistory.capacity + 4}',
    );
  });

  test('remove and clear forget entries', () async {
    final history = TransferHistory(InMemoryTransferHistoryStorage());
    await history.add(_record('a'));
    await history.add(_record('b'));
    await history.remove('a');
    expect(history.records.map((r) => r.transferId), ['b']);
    await history.clear();
    expect(history.records, isEmpty);
  });

  test('errors map to the right failure kind', () {
    expect(
      transferFailureKind(TransferStorageException('t', 'x', outOfSpace: true)),
      TransferFailureKind.outOfSpace,
    );
    expect(
      transferFailureKind(TransferStorageException('t', 'x')),
      TransferFailureKind.saveFailed,
    );
    expect(
      transferFailureKind(TransferConnectionException('t', 'x')),
      TransferFailureKind.connection,
    );
    expect(
      transferFailureKind(TransferSourceException('t', 'x')),
      TransferFailureKind.sourceUnreadable,
    );
    expect(
      transferFailureKind(
        TransferBatchDeclinedException(TransferCancelReason.declined, 'no'),
      ),
      TransferFailureKind.declined,
    );
    expect(
      transferFailureKind(
        TransferCancelledException('t', 'Declined by recipient'),
      ),
      TransferFailureKind.declined,
    );
  });
}
