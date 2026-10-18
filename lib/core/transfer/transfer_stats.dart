/// Timing summary of one finished transfer, for measuring speed on real
/// devices. Holds sizes and durations only: never file names or contents.
class TransferStats {
  final bool outbound;
  final int bytes;
  final int chunkSize;

  /// Sender's in-flight chunk limit (0 on the receiver).
  final int windowChunks;
  final Duration elapsed;

  /// Sender: time awaiting source reads. Receiver: time awaiting disk writes.
  final Duration ioTime;

  /// Sender: time awaiting encrypt + socket write of chunks.
  final Duration sendTime;

  /// Receiver: time spent on the final SHA-256 check.
  final Duration verifyTime;
  final int retransmits;
  final int acks;
  final bool succeeded;
  final DateTime finishedAt;

  /// Link the transfer used ("lan", "wifiDirect", "ble"), when known.
  final String? link;

  TransferStats({
    required this.outbound,
    required this.bytes,
    required this.chunkSize,
    this.windowChunks = 0,
    required this.elapsed,
    this.ioTime = Duration.zero,
    this.sendTime = Duration.zero,
    this.verifyTime = Duration.zero,
    this.retransmits = 0,
    this.acks = 0,
    required this.succeeded,
    DateTime? finishedAt,
    this.link,
  }) : finishedAt = finishedAt ?? DateTime.now();

  TransferStats withLink(String? link) => TransferStats(
    outbound: outbound,
    bytes: bytes,
    chunkSize: chunkSize,
    windowChunks: windowChunks,
    elapsed: elapsed,
    ioTime: ioTime,
    sendTime: sendTime,
    verifyTime: verifyTime,
    retransmits: retransmits,
    acks: acks,
    succeeded: succeeded,
    finishedAt: finishedAt,
    link: link,
  );

  /// Average throughput in MB/s (10^6 bytes) over the whole transfer.
  double get megabytesPerSecond {
    final seconds = elapsed.inMicroseconds / 1e6;
    return seconds > 0 ? bytes / 1e6 / seconds : 0;
  }

  String summary() {
    String ms(Duration d) => '${d.inMilliseconds} ms';
    return '${outbound ? 'sent' : 'received'} ${(bytes / 1e6).toStringAsFixed(1)} MB '
        'in ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s '
        '= ${megabytesPerSecond.toStringAsFixed(1)} MB/s; '
        '${link != null ? 'over $link; ' : ''}'
        'chunk ${chunkSize ~/ 1024} KiB'
        '${windowChunks > 0 ? ' x$windowChunks' : ''}; '
        '${outbound ? 'read' : 'write'} ${ms(ioTime)}'
        '${outbound ? ', send ${ms(sendTime)}' : ', verify ${ms(verifyTime)}'}'
        ', acks $acks, retransmits $retransmits'
        '${succeeded ? '' : ' (failed)'}';
  }
}

/// The most recent transfer timings, newest first.
class TransferStatsLog {
  static const int capacity = 10;
  final List<TransferStats> _entries = [];

  List<TransferStats> get recent => List.unmodifiable(_entries);

  void record(TransferStats stats) {
    _entries.insert(0, stats);
    if (_entries.length > capacity) _entries.removeLast();
  }
}
