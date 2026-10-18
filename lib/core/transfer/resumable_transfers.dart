import 'dart:async';
import 'dart:io';

import 'package:vayu/core/logging/app_logger.dart';

/// A partly received file kept after its connection dropped.
class PartialTransfer {
  /// The staging file (`<target>.vayu.tmp`) holding the received prefix.
  final String stagingPath;

  /// Chunks received in order from the start; everything after is redone.
  final int contiguousChunks;

  /// Bytes those chunks cover.
  final int contiguousBytes;

  const PartialTransfer({
    required this.stagingPath,
    required this.contiguousChunks,
    required this.contiguousBytes,
  });
}

/// Receiver-side memory of interrupted transfers, so offering the same file
/// again (Retry, Share again) continues where it stopped instead of
/// starting over.
///
/// A partial file is matched only to the same sender, file hash, size and
/// chunk size; files offered before their hash was known (`late-hash-v1`)
/// are matched by file name instead. The final SHA-256 check still covers the
/// whole file. Unused partial files are deleted after [keepFor].
class ResumableTransfers {
  final Duration keepFor;
  final Map<String, (PartialTransfer, Timer)> _partials = {};

  ResumableTransfers({this.keepFor = const Duration(minutes: 30)});

  static String keyFor({
    required String senderDeviceId,
    required String sha256,
    required int totalBytes,
    required int chunkSize,
  }) =>
      '${senderDeviceId.toLowerCase()}|${sha256.toLowerCase()}|$totalBytes|$chunkSize';

  /// Key for a file offered before its hash was known.
  static String keyForName({
    required String senderDeviceId,
    required String fileName,
    required int totalBytes,
    required int chunkSize,
  }) => '${senderDeviceId.toLowerCase()}|name:$fileName|$totalBytes|$chunkSize';

  /// Remembers [partial] under [key], replacing (and deleting) an older one.
  void keep(String key, PartialTransfer partial) {
    final previous = _partials.remove(key);
    if (previous != null) {
      previous.$2.cancel();
      if (previous.$1.stagingPath != partial.stagingPath) {
        _delete(previous.$1.stagingPath);
      }
    }
    final timer = Timer(keepFor, () {
      final expired = _partials.remove(key);
      if (expired != null) _delete(expired.$1.stagingPath);
    });
    _partials[key] = (partial, timer);
    AppLogger.info(
      'ResumableTransfers',
      'Kept ${partial.contiguousBytes} bytes to resume later',
    );
  }

  /// Takes the partial file for [key] if it is still on disk and complete
  /// up to its recorded size.
  PartialTransfer? take(String key) {
    final entry = _partials.remove(key);
    if (entry == null) return null;
    entry.$2.cancel();
    final partial = entry.$1;
    try {
      final file = File(partial.stagingPath);
      if (file.existsSync() && file.lengthSync() >= partial.contiguousBytes) {
        return partial;
      }
    } catch (_) {}
    _delete(partial.stagingPath);
    return null;
  }

  /// Staging files currently kept for a later resume.
  Set<String> get keptPaths => {
    for (final entry in _partials.values) entry.$1.stagingPath,
  };

  /// Forgets every kept partial file. Files left on disk are removed by the
  /// staging cleanup before the next receive.
  void dispose() {
    for (final entry in _partials.values) {
      entry.$2.cancel();
    }
    _partials.clear();
  }

  static void _delete(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
