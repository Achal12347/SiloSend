import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/transfer/transfer_stats.dart';

TransferStats _file({
  required DateTime end,
  required int seconds,
  int bytes = 10 * 1000 * 1000,
  String? batch = 'b1',
  bool outbound = true,
  bool ok = true,
}) => TransferStats(
  outbound: outbound,
  bytes: bytes,
  chunkSize: 1024 * 1024,
  elapsed: Duration(seconds: seconds),
  succeeded: ok,
  finishedAt: end,
  batchId: batch,
);

void main() {
  group('batch totals', () {
    test('measures the whole batch, including time between files', () {
      final t0 = DateTime(2026, 10, 18, 12);
      final log = TransferStatsLog()
        // File 1: 0-10 s, file 2: 12-22 s (a 2 s gap between them).
        ..record(_file(end: t0.add(const Duration(seconds: 10)), seconds: 10))
        ..record(_file(end: t0.add(const Duration(seconds: 22)), seconds: 10));

      final batch = log.batches().single;
      expect(batch.files, 2);
      expect(batch.bytes, 20 * 1000 * 1000);
      expect(batch.wallTime, const Duration(seconds: 22));
      expect(batch.fileTime, const Duration(seconds: 20));
      expect(batch.betweenFiles, const Duration(seconds: 2));
      expect(batch.megabytesPerSecond, closeTo(20 / 22, 1e-9));
      expect(batch.allSucceeded, isTrue);
    });

    test('single files and the two directions are kept apart', () {
      final t = DateTime(2026, 10, 18);
      final log = TransferStatsLog()
        ..record(_file(end: t, seconds: 1, batch: null))
        ..record(_file(end: t, seconds: 1, outbound: false))
        ..record(_file(end: t, seconds: 1, ok: false));

      final batches = log.batches();
      expect(batches, hasLength(2));
      final sent = batches.firstWhere((b) => b.outbound);
      expect(sent.files, 1);
      expect(sent.allSucceeded, isFalse);
    });
  });

  test('keeps enough entries for a folder of a few hundred files', () {
    final log = TransferStatsLog();
    for (var i = 0; i < TransferStatsLog.capacity + 5; i++) {
      log.record(_file(end: DateTime(2026), seconds: 1));
    }
    expect(log.recent, hasLength(TransferStatsLog.capacity));
  });

  test('the environment is attached after the transfer is recorded', () async {
    final log = TransferStatsLog()
      ..environmentProbe = () async => 'Wi-Fi 2.4 GHz, 72 Mbps, -60 dBm';
    log.record(_file(end: DateTime(2026), seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(log.recent.single.environment, contains('2.4 GHz'));
    expect(log.report(), contains('2.4 GHz'));
  });

  test('a failing probe leaves the measurement as it was', () async {
    final log = TransferStatsLog()
      ..environmentProbe = () async => throw StateError('no channel');
    log.record(_file(end: DateTime(2026), seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(log.recent.single.environment, isNull);
  });

  test('the receiver summary separates disk time from hash waiting', () {
    final stats = TransferStats(
      outbound: false,
      bytes: 1000000,
      chunkSize: 1024 * 1024,
      elapsed: const Duration(seconds: 1),
      ioTime: const Duration(milliseconds: 900),
      diskWriteTime: const Duration(milliseconds: 100),
      hashWaitTime: const Duration(milliseconds: 800),
      crcTime: const Duration(milliseconds: 7),
      cryptoTime: const Duration(milliseconds: 9),
      succeeded: true,
    );
    final text = stats.summary();
    expect(text, contains('disk 100 ms'));
    expect(text, contains('hash wait 800 ms'));
    expect(text, contains('crc 7 ms'));
    expect(text, contains('crypto 9 ms'));
  });
}
