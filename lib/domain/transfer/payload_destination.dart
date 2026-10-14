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

/// Filesystem-backed destination sink writing to an atomic staging file
/// (`<path>.vayu.tmp`) before moving to the target path upon integrity verification.
class FilePayloadDestination implements PayloadDestination {
  final String targetFilePath;

  @override
  final int totalBytes;

  late final File _tmpFile;
  RandomAccessFile? _raf;
  bool _isFinalized = false;
  bool _isAborted = false;

  FilePayloadDestination({
    required this.targetFilePath,
    required this.totalBytes,
  }) {
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'Cannot be negative');
    }
    _tmpFile = File('$targetFilePath.vayu.tmp');
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
        _raf = await _tmpFile.open(mode: FileMode.write);
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

    try {
      final destFile = File(targetFilePath);
      if (destFile.existsSync()) {
        destFile.deleteSync();
      }
      if (_tmpFile.existsSync()) {
        await _tmpFile.rename(targetFilePath);
      }
      _isFinalized = true;
    } catch (e) {
      throw TransferStorageException(
        '',
        'Failed to promote staging file to $targetFilePath: $e',
        outOfSpace: isOutOfSpaceError(e),
      );
    }
  }

  @override
  Future<void> abortAndCleanup() async {
    _isAborted = true;
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
    if (_raf != null) {
      try {
        await _raf!.close();
      } catch (_) {}
      _raf = null;
    }
  }
}
