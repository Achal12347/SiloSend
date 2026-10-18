import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/utils/file_hash.dart';

// ENOSPC is 28 on Linux/Android and macOS; ERROR_DISK_FULL is 112 on Windows.
const _outOfSpaceErrorCodes = {28, 112};

/// True when [error] is the OS reporting that the disk is full.
bool isOutOfSpaceError(Object error) {
  if (error is TransferStorageException) return error.outOfSpace;
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    return code != null && _outOfSpaceErrorCodes.contains(code);
  }
  return false;
}

/// In-memory destination sink for received transfer payloads.
class MemoryPayloadDestination implements PayloadDestination {
  @override
  final int totalBytes;

  late final Uint8List _buffer;
  bool _isFinalized = false;
  bool _isAborted = false;

  MemoryPayloadDestination({required this.totalBytes}) {
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'Cannot be negative');
    }
    _buffer = Uint8List(totalBytes);
  }

  /// Returns the internal buffer bytes.
  Uint8List get buffer {
    if (_isAborted) {
      throw TransferStorageException('', 'Destination has been aborted');
    }
    return _buffer;
  }

  @override
  Future<void> writeChunk(int offset, Uint8List data) async {
    if (_isAborted) {
      throw TransferStorageException('', 'Destination has been aborted');
    }
    if (_isFinalized) {
      throw TransferStorageException('', 'Destination is already finalized');
    }
    if (offset < 0 || offset + data.length > totalBytes) {
      throw TransferStorageException(
        '',
        'Chunk write bounds ($offset + ${data.length}) exceed totalBytes ($totalBytes)',
      );
    }
    _buffer.setRange(offset, offset + data.length, data);
  }

  @override
  Future<String> computeSha256() async {
    final digest = crypto.sha256.convert(_buffer);
    return digest.toString();
  }

  @override
  Future<void> finalize() async {
    _isFinalized = true;
  }

  @override
  Future<void> abortAndCleanup() async {
    _isAborted = true;
    _buffer.fillRange(0, _buffer.length, 0);
  }

  @override
  Future<void> close() async {}
}

/// [path] for [n] = 0, otherwise `name (n).ext` in the same folder. Shared by
/// destination reservation and by [FilePayloadDestination.finalize] so both
/// number duplicates the same way.
String numberedPath(String path, int n) {
  if (n == 0) return path;
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final name = path.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  return '${path.substring(0, slash + 1)}$base ($n)$ext';
}

/// Filesystem-backed destination sink writing to an atomic staging file
/// (`<path>.vayu.tmp`) before moving to the target path upon integrity verification.
class FilePayloadDestination implements PayloadDestination {
  /// Suffix of the staging file a transfer writes before verification.
  static const String stagingSuffix = '.vayu.tmp';

  /// Where the received file lives (or will live). Starts as the reserved
  /// path; [finalize] moves to the next free name if that one was taken
  /// meanwhile, so screens and history must read it after completion.
  String get targetFilePath => _targetFilePath;
  String _targetFilePath;

  @override
  final int totalBytes;

  late final File _tmpFile;
  RandomAccessFile? _raf;
  bool _isFinalized = false;
  bool _isAborted = false;

  /// Files at least this large are hashed while they arrive.
  static const int streamingHashMinBytes = 4 * 1024 * 1024;

  // Hash of the bytes written so far, as long as writes arrive in order.
  // Any gap or rewrite drops it and verification re-reads the file.
  BackgroundSha256? _streamingHash;
  int _hashedUpTo = 0;
  bool _streamingHashBroken = false;

  /// Completes when the hashing backlog allows the next write.
  Future<void> _feedStreamingHash(int offset, Uint8List data) async {
    if (_streamingHashBroken || totalBytes < streamingHashMinBytes) return;
    if (offset != _hashedUpTo) {
      _streamingHashBroken = true;
      _streamingHash?.dispose();
      _streamingHash = null;
      return;
    }
    _hashedUpTo += data.length;
    await (_streamingHash ??= BackgroundSha256()).add(data);
  }

  void _dropStreamingHash() {
    _streamingHashBroken = true;
    _streamingHash?.dispose();
    _streamingHash = null;
  }

  /// Bytes already in the staging file from an interrupted transfer of the
  /// same file; writing continues after them instead of starting over.
  final int resumeFromBytes;

  FilePayloadDestination({
    required String targetFilePath,
    required this.totalBytes,
    this.resumeFromBytes = 0,
  }) : _targetFilePath = targetFilePath {
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'Cannot be negative');
    }
    _tmpFile = File('$targetFilePath$stagingSuffix');
    // The kept prefix is not hashed here; verification re-reads the file.
    if (resumeFromBytes > 0) _streamingHashBroken = true;
  }

  /// Closes the staging file and leaves it on disk for a later resume.
  /// The destination accepts no more writes afterwards.
  Future<String> detachKeepingStaging() async {
    _isAborted = true;
    _dropStreamingHash();
    if (_writeQueue != null) {
      try {
        await _writeQueue;
      } catch (_) {}
    }
    if (_raf != null) {
      try {
        await _raf!.flush();
        await _raf!.close();
      } catch (_) {}
      _raf = null;
    }
    return _tmpFile.path;
  }

  /// Path of the temporary staging file.
  String get stagingPath => _tmpFile.path;

  Future<void> _ensureOpen() async {
    if (_isAborted) {
      throw TransferStorageException('', 'Destination has been aborted');
    }
    if (_isFinalized) {
      throw TransferStorageException('', 'Destination is already finalized');
    }
    if (_raf == null) {
      try {
        if (!_tmpFile.parent.existsSync()) {
          _tmpFile.parent.createSync(recursive: true);
        }
        if (resumeFromBytes > 0 && _tmpFile.existsSync()) {
          // Keep the received prefix; drop anything after it (chunks that
          // arrived out of order are sent again).
          _raf = await _tmpFile.open(mode: FileMode.append);
          await _raf!.truncate(resumeFromBytes);
        } else {
          _raf = await _tmpFile.open(mode: FileMode.write);
        }
      } catch (e) {
        throw TransferStorageException(
          '',
          'Failed to open staging file ${_tmpFile.path}: $e',
        );
      }
    }
  }

  Future<void>? _writeQueue;

  @override
  Future<void> writeChunk(int offset, Uint8List data) async {
    final prev = _writeQueue;
    final c = Completer<void>();
    _writeQueue = c.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }

    try {
      await _ensureOpen();
      if (offset < 0 || offset + data.length > totalBytes) {
        throw TransferStorageException(
          '',
          'Write range ($offset + ${data.length}) exceeds totalBytes ($totalBytes)',
        );
      }
      await _raf!.setPosition(offset);
      await _raf!.writeFrom(data);
      // Writes wait while hashing is behind, so a slow phone slows the
      // sender (through later ACKs) instead of queueing copies in memory.
      await _feedStreamingHash(offset, data);
    } on TransferStorageException {
      rethrow;
    } catch (e) {
      throw TransferStorageException(
        '',
        'Failed to write chunk at offset $offset: $e',
        outOfSpace: isOutOfSpaceError(e),
      );
    } finally {
      c.complete();
    }
  }

  @override
  Future<String> computeSha256() async {
    if (totalBytes == 0) {
      if (!_tmpFile.parent.existsSync()) {
        _tmpFile.parent.createSync(recursive: true);
      }
      if (!_tmpFile.existsSync()) {
        _tmpFile.createSync();
      }
      return crypto.sha256.convert(const []).toString();
    }
    if (_writeQueue != null) {
      try {
        await _writeQueue;
      } catch (_) {}
    }
    if (_raf != null) {
      await _raf!.flush();
      await _raf!.close();
      _raf = null;
    }
    if (!_tmpFile.existsSync()) {
      throw TransferStorageException(
        '',
        'Staging file does not exist to compute SHA-256',
      );
    }
    final streaming = _streamingHash;
    _streamingHash = null;
    if (streaming != null &&
        !_streamingHashBroken &&
        _hashedUpTo == totalBytes) {
      try {
        return await streaming.digest();
      } catch (_) {
        // The worker failed; hash the file instead.
      }
    } else {
      streaming?.dispose();
    }
    try {
      return await sha256OfFile(_tmpFile.path, length: totalBytes);
    } catch (e) {
      throw TransferStorageException('', 'Failed to hash staging file: $e');
    }
  }

  @override
  Future<void> finalize() async {
    if (_isFinalized) return;
    if (_raf != null) {
      await _raf!.flush();
      await _raf!.close();
      _raf = null;
    }

    if (!_tmpFile.existsSync()) {
      // The verified bytes are gone; never report a file that is not there.
      throw TransferStorageException(
        '',
        'Staging file ${_tmpFile.path} disappeared before it could be saved',
      );
    }
    // Never delete or replace an existing file: claim the target name by
    // creating it exclusively (atomic), then move the staging file onto that
    // claim. A name taken since reservation moves us to the next free one.
    for (var n = 0; ; n++) {
      final candidate = numberedPath(_targetFilePath, n);
      final claim = File(candidate);
      try {
        await claim.create(exclusive: true);
      } on FileSystemException catch (e) {
        if (claim.existsSync()) continue;
        throw TransferStorageException(
          '',
          'Could not create $candidate: $e',
          outOfSpace: isOutOfSpaceError(e),
        );
      }
      try {
        await _tmpFile.rename(candidate);
      } catch (e) {
        // Our own empty claim only; the staging file is left for cleanup.
        try {
          await claim.delete();
        } catch (_) {}
        throw TransferStorageException(
          '',
          'Failed to promote staging file to $candidate: $e',
          outOfSpace: isOutOfSpaceError(e),
        );
      }
      _targetFilePath = candidate;
      _isFinalized = true;
      return;
    }
  }

  @override
  Future<void> abortAndCleanup() async {
    _isAborted = true;
    _dropStreamingHash();
    if (_writeQueue != null) {
      try {
        await _writeQueue;
      } catch (_) {}
    }
    if (_raf != null) {
      try {
        await _raf!.close();
      } catch (_) {}
      _raf = null;
    }
    try {
      if (_tmpFile.existsSync()) {
        _tmpFile.deleteSync();
      }
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    _dropStreamingHash();
    if (_raf != null) {
      try {
        await _raf!.close();
      } catch (_) {}
      _raf = null;
    }
  }
}
