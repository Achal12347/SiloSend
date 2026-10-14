/// Human-readable formatting shared by transfer screens and cards.
library;

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatSpeed(double bytesPerSecond) {
  if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

/// Remaining time, or null while the estimate is not yet meaningful.
String? formatRemaining(int? seconds) {
  if (seconds == null || seconds <= 0) return null;
  if (seconds < 60) return '${seconds}s left';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ${seconds % 60}s left';
  return '${minutes ~/ 60}h ${minutes % 60}m left';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today 14:05", "Yesterday 09:30" or "12 Oct 18:20" relative to [now].
String formatWhen(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  final day = DateTime(time.year, time.month, time.day);
  final today = DateTime(current.year, current.month, current.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today $hh:$mm';
  if (diff == 1) return 'Yesterday $hh:$mm';
  final year = time.year == current.year ? '' : ' ${time.year}';
  return '${time.day} ${_months[time.month - 1]}$year $hh:$mm';
}

/// Plain-language reason for a stored failure kind (see TransferFailureKind).
String describeFailureKind(String? kind) {
  switch (kind) {
    case 'connection':
      return 'Connection lost';
    case 'timeout':
      return 'The other device stopped responding';
    case 'outOfSpace':
      return 'Not enough storage space';
    case 'saveFailed':
      return 'Could not be saved';
    case 'sourceUnreadable':
      return 'The file could not be read';
    case 'corrupted':
      return 'Arrived damaged and was discarded';
    case 'unconfirmed':
      return 'Not confirmed by the other device';
    case 'declined':
      return 'Declined';
    case 'cancelled':
      return 'Cancelled';
    default:
      return 'Did not complete';
  }
}
