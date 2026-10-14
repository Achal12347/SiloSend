import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/utils/file_hash.dart';

/// In-memory payload source backed by a contiguous [Uint8List].
class MemoryPayloadSource implements PayloadSource {
  final Uint8List _data;

  MemoryPayloadSource(this._data);

  @override
  int get length => _data.length;

  @override
  Future<Uint8List> readChunk(int offset, int length) async {
    if (offset < 0 || offset > _data.length) {
      throw RangeError.range(offset, 0, _data.length, 'offset');
    }
    final end = (offset + length).clamp(0, _data.length);
    return Uint8List.fromList(_data.sublist(offset, end));
  }

  @override
  Stream<Uint8List> openStream({
    int startByte = 0,
    int chunkSize = 64 * 1024,
  }) async* {
    if (startByte < 0 || startByte > _data.length) {
      throw RangeError.range(startByte, 0, _data.length, 'startByte');
    }
    int offset = startByte;
    while (offset < _data.length) {
      final end = (offset + chunkSize).clamp(0, _data.length);
      yield Uint8List.fromList(_data.sublist(offset, end));
      offset = end;
    }
  }

  @override
  Future<String> computeSha256() async {
    final digest = crypto.sha256.convert(_data);
    return digest.toString();
  }

  @override
  Future<void> close() async {}
}

/// Disk file-backed payload source streaming chunks on-demand with zero-full-memory-loading.
class FilePayloadSource implements PayloadSource {
  final File file;
  late final int _length;
  RandomAccessFile? _raf;

  FilePayloadSource(this.file) {
    if (!file.existsSync()) {
      throw FileSystemException('Source file does not exist', file.path);
    }
    _length = file.lengthSync();
  }

  @override
  int get length => _length;

  Future<void>? _readQueue;

  @override
  Future<Uint8List> readChunk(int offset, int length) async {
    final prev = _readQueue;
    final c = Completer<void>();
    _readQueue = c.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }

    try {
      if (offset < 0 || offset > _length) {
        throw RangeError.range(offset, 0, _length, 'offset');
      }
      final actualLength = (offset + length > _length)
          ? (_length - offset)
          : length;
      if (actualLength <= 0) return Uint8List(0);

      _raf ??= await file.open(mode: FileMode.read);
      await _raf!.setPosition(offset);
      final bytes = await _raf!.read(actualLength);
      return bytes;
    } finally {
      c.complete();
    }
  }

  @override
  Stream<Uint8List> openStream({int startByte = 0}) {
    if (startByte < 0 || startByte > _length) {
      throw RangeError.range(startByte, 0, _length, 'startByte');
    }
    return file.openRead(startByte).map((chunk) => Uint8List.fromList(chunk));
  }

  @override
  Future<String> computeSha256() => sha256OfFile(file.path);

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
