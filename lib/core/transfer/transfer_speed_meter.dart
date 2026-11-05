/// Average speed over the last few seconds.
///
/// Acknowledgements arrive in bursts of whole chunks, so comparing one short
/// sample with the next made the shown speed jump around even on a steady
/// link. The bytes reported here are real; only the averaging window is longer.
class TransferSpeedMeter {
  final Duration window;
  final List<(DateTime, int)> _samples = [];

  TransferSpeedMeter({this.window = const Duration(seconds: 3)});

  /// Records [totalBytes] done at [now] and returns bytes per second, or 0
  /// until two samples at least 250 ms apart exist.
  double update(int totalBytes, DateTime now) {
    _samples.add((now, totalBytes));
    final cutoff = now.subtract(window);
    // Keeps one sample older than the window, so it stays fully covered.
    while (_samples.length > 2 && _samples[1].$1.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
    final (firstAt, firstBytes) = _samples.first;
    final ms = now.difference(firstAt).inMilliseconds;
    if (ms < 250) return 0;
    return (totalBytes - firstBytes) / (ms / 1000.0);
  }
}
