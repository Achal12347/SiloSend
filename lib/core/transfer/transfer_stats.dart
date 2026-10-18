/// Timing summary of one finished transfer, for measuring speed on real
/// devices. Holds sizes and durations only: never file names or contents.
///
/// Every value is measured on this phone while the transfer ran; nothing is
/// estimated. Where a stage can overlap with others (pipelined sends), its
/// time is the sum of its own waits, so stages need not add up to [elapsed].
class TransferStats {
  final bool outbound;
  final int bytes;
  final int chunkSize;

  /// Sender's in-flight chunk limit (0 on the receiver).
  final int windowChunks;
  final Duration elapsed;

  /// Sender: time awaiting source reads. Receiver: time awaiting each chunk's
  /// write call (disk write plus any wait for the hash, see below).
  final Duration ioTime;

  /// Sender: time awaiting encrypt + socket write of chunks.
  final Duration sendTime;

  /// Receiver: time spent on the final SHA-256 check.
  final Duration verifyTime;

  /// Computing (sender) or checking (receiver) the per-chunk CRC32.
  final Duration crcTime;

  /// AES-GCM calls of this phone while the transfer ran (all sessions).
  final Duration cryptoTime;

  /// Receiver: the part of [ioTime] spent writing to storage.
  final Duration diskWriteTime;

  /// Receiver: the part of [ioTime] spent waiting for the streaming SHA-256
  /// to catch up (writes pause while it is more than 8 MiB behind).
  final Duration hashWaitTime;

  final int retransmits;
  final int acks;
  final bool succeeded;
  final DateTime finishedAt;

  /// Link the transfer used ("lan", "wifiDirect", "ble"), when known.
  final String? link;

  /// Batch the file belonged to, so a folder can be measured as a whole.
  final String? batchId;

  /// Wi-Fi band and speed, thermal state and Wi-Fi Direct group as the
  /// platform reported them when the transfer ended.
  final String? environment;

  TransferStats({
    required this.outbound,
    required this.bytes,
    required this.chunkSize,
    this.windowChunks = 0,
    required this.elapsed,
    this.ioTime = Duration.zero,
    this.sendTime = Duration.zero,
    this.verifyTime = Duration.zero,
    this.crcTime = Duration.zero,
    this.cryptoTime = Duration.zero,
    this.diskWriteTime = Duration.zero,
    this.hashWaitTime = Duration.zero,
    this.retransmits = 0,
    this.acks = 0,
    required this.succeeded,
    DateTime? finishedAt,
    this.link,
    this.batchId,
    this.environment,
  }) : finishedAt = finishedAt ?? DateTime.now();

  DateTime get startedAt => finishedAt.subtract(elapsed);

  TransferStats _copy({String? link, String? environment}) => TransferStats(
    outbound: outbound,
    bytes: bytes,
    chunkSize: chunkSize,
    windowChunks: windowChunks,
    elapsed: elapsed,
    ioTime: ioTime,
    sendTime: sendTime,
    verifyTime: verifyTime,
    crcTime: crcTime,
    cryptoTime: cryptoTime,
    diskWriteTime: diskWriteTime,
    hashWaitTime: hashWaitTime,
    retransmits: retransmits,
    acks: acks,
    succeeded: succeeded,
    finishedAt: finishedAt,
    link: link ?? this.link,
    batchId: batchId,
    environment: environment ?? this.environment,
  );

  TransferStats withLink(String? link) => _copy(link: link);

  TransferStats withEnvironment(String? environment) =>
      _copy(environment: environment);

  /// Average throughput in MB/s (10^6 bytes) over the whole transfer.
  double get megabytesPerSecond {
    final seconds = elapsed.inMicroseconds / 1e6;
    return seconds > 0 ? bytes / 1e6 / seconds : 0;
  }

  String summary() {
    String ms(Duration d) => '${d.inMilliseconds} ms';
    final stages = outbound
        ? 'read ${ms(ioTime)}, send ${ms(sendTime)}'
        : 'write ${ms(ioTime)} (disk ${ms(diskWriteTime)}, '
              'hash wait ${ms(hashWaitTime)}), verify ${ms(verifyTime)}';
    return '${outbound ? 'sent' : 'received'} ${(bytes / 1e6).toStringAsFixed(1)} MB '
        'in ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s '
        '= ${megabytesPerSecond.toStringAsFixed(1)} MB/s; '
        '${link != null ? 'over $link; ' : ''}'
        'chunk ${chunkSize ~/ 1024} KiB'
        '${windowChunks > 0 ? ' x$windowChunks' : ''}; '
        '$stages, crc ${ms(crcTime)}, crypto ${ms(cryptoTime)}'
        ', acks $acks, retransmits $retransmits'
        '${succeeded ? '' : ' (failed)'}'
        '${environment != null ? '; $environment' : ''}';
  }
}

/// A batch (several files or a folder) measured as a whole.
class BatchStats {
  final String batchId;
  final bool outbound;
  final int files;
  final int bytes;

  /// From the first file's start to the last file's end.
  final Duration wallTime;

  /// Sum of the files' own transfer times.
  final Duration fileTime;
  final bool allSucceeded;

  const BatchStats({
    required this.batchId,
    required this.outbound,
    required this.files,
    required this.bytes,
    required this.wallTime,
    required this.fileTime,
    required this.allSucceeded,
  });

  /// Time between files (offer, verify and save of the previous file, ...).
  Duration get betweenFiles {
    final gap = wallTime - fileTime;
    return gap.isNegative ? Duration.zero : gap;
  }

  /// End-to-end speed of the whole batch, gaps included.
  double get megabytesPerSecond {
    final seconds = wallTime.inMicroseconds / 1e6;
    return seconds > 0 ? bytes / 1e6 / seconds : 0;
  }

  String summary() =>
      '${outbound ? 'sent' : 'received'} $files files, '
      '${(bytes / 1e6).toStringAsFixed(1)} MB in '
      '${(wallTime.inMilliseconds / 1000).toStringAsFixed(1)} s '
      '= ${megabytesPerSecond.toStringAsFixed(1)} MB/s end to end; '
      'between files ${(betweenFiles.inMilliseconds / 1000).toStringAsFixed(1)} s'
      '${allSucceeded ? '' : ' (some failed)'}';
}

/// The most recent transfer timings, newest first.
class TransferStatsLog {
  /// Enough to cover a folder of a few hundred files.
  static const int capacity = 300;
  final List<TransferStats> _entries = [];

  /// Reads Wi-Fi, thermal and Wi-Fi Direct state for a finished transfer.
  /// Set by the app; null in tests.
  Future<String?> Function()? environmentProbe;

  List<TransferStats> get recent => List.unmodifiable(_entries);

  void record(TransferStats stats) {
    _entries.insert(0, stats);
    if (_entries.length > capacity) _entries.removeLast();
    final probe = environmentProbe;
    if (probe != null) _attachEnvironment(stats, probe);
  }

  Future<void> _attachEnvironment(
    TransferStats stats,
    Future<String?> Function() probe,
  ) async {
    String? environment;
    try {
      environment = await probe();
    } catch (_) {
      return;
    }
    if (environment == null) return;
    final i = _entries.indexOf(stats);
    if (i >= 0) _entries[i] = stats.withEnvironment(environment);
  }

  /// Batches in the log, newest first. Single files are not batches.
  List<BatchStats> batches() {
    final groups = <(String, bool), List<TransferStats>>{};
    for (final s in _entries) {
      final id = s.batchId;
      if (id == null) continue;
      groups.putIfAbsent((id, s.outbound), () => []).add(s);
    }
    final result = <BatchStats>[];
    for (final MapEntry(key: (id, outbound), value: files) in groups.entries) {
      final start = files
          .map((s) => s.startedAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final end = files
          .map((s) => s.finishedAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      result.add(
        BatchStats(
          batchId: id,
          outbound: outbound,
          files: files.length,
          bytes: files.fold(0, (sum, s) => sum + s.bytes),
          wallTime: end.difference(start),
          fileTime: files.fold(Duration.zero, (sum, s) => sum + s.elapsed),
          allSucceeded: files.every((s) => s.succeeded),
        ),
      );
    }
    return result;
  }

  /// Plain-text report for copying out of the app (no file names).
  String report({String? header}) {
    final lines = <String>[
      ?header,
      for (final b in batches()) 'Batch: ${b.summary()}',
      for (final s in _entries) s.summary(),
    ];
    return lines.join('\n');
  }
}
