import 'dart:async';
import 'dart:convert';
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
///
/// With [indexFile] (app-private), the list survives an app restart or a
/// phone restart: [load] brings back what is still on disk and not expired.
/// Before, a killed app lost every partial file and the next receive deleted
/// it as stale.
class ResumableTransfers {
  final Duration keepFor;
  final File? indexFile;
  final Map<String, (PartialTransfer, Timer, DateTime)> _partials = {};
  Future<void> _saving = Future.value();

  /// Only Vayu staging files are ever kept or deleted from a loaded index.
  static const String stagingSuffix = '.vayu.tmp';

  ResumableTransfers({
    this.keepFor = const Duration(minutes: 30),
    this.indexFile,
  });

  /// Restores partial files kept before the app stopped. Expired ones and
  /// ones whose file is gone or shorter than recorded are dropped (and their
  /// files deleted).
  Future<void> load() async {
    final file = indexFile;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) return;
      final entries = decoded['partials'];
      if (entries is! Map) return;
      final now = DateTime.now();
      var restored = 0;
      for (final MapEntry(:key, :value) in entries.entries) {
        if (key is! String || value is! Map) continue;
        final path = value['path'], chunks = value['chunks'];
        final bytes = value['bytes'], until = value['until'];
        if (path is! String ||
            !path.endsWith(stagingSuffix) ||
            chunks is! int ||
            bytes is! int ||
            until is! int) {
          continue;
        }
        final expires = DateTime.fromMillisecondsSinceEpoch(until);
        final staging = File(path);
        final usable =
            expires.isAfter(now) &&
            staging.existsSync() &&
            staging.lengthSync() >= bytes;
        if (!usable) {
          _delete(path);
          continue;
        }
        _remember(
          key,
          PartialTransfer(
            stagingPath: path,
            contiguousChunks: chunks,
            contiguousBytes: bytes,
          ),
          expires,
        );
        restored++;
      }
      if (restored > 0) {
        AppLogger.info(
          'ResumableTransfers',
          'Restored $restored partial file(s) after a restart',
        );
      }
      _persist();
    } catch (e) {
      AppLogger.warning('ResumableTransfers', 'Resume list unreadable: $e');
    }
  }

  void _remember(String key, PartialTransfer partial, DateTime expires) {
    final timer = Timer(expires.difference(DateTime.now()), () {
      final expired = _partials.remove(key);
      if (expired != null) {
        _delete(expired.$1.stagingPath);
        _persist();
      }
    });
    _partials[key] = (partial, timer, expires);
  }

  void _persist() {
    final file = indexFile;
    if (file == null) return;
    final snapshot = {
      'version': 1,
      'partials': {
        for (final MapEntry(:key, :value) in _partials.entries)
          key: {
            'path': value.$1.stagingPath,
            'chunks': value.$1.contiguousChunks,
            'bytes': value.$1.contiguousBytes,
            'until': value.$3.millisecondsSinceEpoch,
          },
      },
    };
    _saving = _saving
        .then((_) async {
          await file.parent.create(recursive: true);
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsString(jsonEncode(snapshot), flush: true);
          await tmp.rename(file.path);
        })
        .catchError((Object e) {
          AppLogger.warning(
            'ResumableTransfers',
            'Saving resume list failed: $e',
          );
        });
  }

  /// Completes when the list on disk is up to date (tests).
  Future<void> get saved => _saving;

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
    _remember(key, partial, DateTime.now().add(keepFor));
    _persist();
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
    _persist();
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

  /// Bytes kept on disk for later resumes.
  int get keptBytes =>
      _partials.values.fold(0, (sum, e) => sum + e.$1.contiguousBytes);

  /// Deletes every kept partial file (Your data): those transfers start
  /// over if sent again.
  Future<void> discardAll() async {
    for (final entry in _partials.values) {
      entry.$2.cancel();
      _delete(entry.$1.stagingPath);
    }
    _partials.clear();
    _persist();
    await _saving;
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
