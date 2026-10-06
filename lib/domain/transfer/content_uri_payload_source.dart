import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vayu/core/contracts/transfer_contract.dart';

class _DigestSink implements Sink<crypto.Digest> {
  final void Function(crypto.Digest digest) onDigest;

  _DigestSink(this.onDigest);

  @override
  void add(crypto.Digest digest) => onDigest(digest);

  @override
  void close() {}
}

/// Payload source backed by a platform content URI (such as an Android SAF content:// URI)
/// or an abstract stream descriptor.
///
/// Reads chunks on-demand via platform channel without copying the file or requiring
/// a direct filesystem path.
class ContentUriPayloadSource implements PayloadSource {
  final String uri;
  int _totalBytes;
  final Future<Uint8List> Function(String uri, int offset, int length)
  readChunkCallback;
  final Future<void> Function(String uri)? closeCallback;

  ContentUriPayloadSource({
    required this.uri,
    required int length,
    required this.readChunkCallback,
    this.closeCallback,
  }) : _totalBytes = length;

  @override
  int get length => _totalBytes;

  @override
  Future<Uint8List> readChunk(int offset, int length) async {
    if (offset < 0 || (_totalBytes >= 0 && offset > _totalBytes)) {
      throw RangeError.range(
        offset,
        0,
        _totalBytes >= 0 ? _totalBytes : offset,
        'offset',
      );
    }
    final actualLength = (_totalBytes >= 0 && offset + length > _totalBytes)
        ? (_totalBytes - offset)
        : length;
    if (actualLength <= 0) return Uint8List(0);
    return readChunkCallback(uri, offset, actualLength);
  }

  @override
  Stream<Uint8List> openStream({
    int startByte = 0,
    int chunkSize = 64 * 1024,
  }) async* {
    int offset = startByte;
    while (_totalBytes < 0 || offset < _totalBytes) {
      final toRead = (_totalBytes >= 0 && offset + chunkSize > _totalBytes)
          ? (_totalBytes - offset)
          : chunkSize;
      if (toRead <= 0) break;
      final chunk = await readChunk(offset, toRead);
      if (chunk.isEmpty) break;
      yield chunk;
      offset += chunk.length;
    }
  }

  @override
  Future<String> computeSha256() async {
    var streamedLength = 0;
    crypto.Digest? digest;
    final sink = crypto.sha256.startChunkedConversion(
      _DigestSink((value) => digest = value),
    );

    await for (final chunk in openStream()) {
      streamedLength += chunk.length;
      sink.add(chunk);
    }
    sink.close();
    _totalBytes = streamedLength;

    final resolvedDigest = digest;
    if (resolvedDigest == null) {
      throw StateError('Unable to compute content URI SHA-256 digest');
    }
    return resolvedDigest.toString();
  }

  @override
  Future<void> close() async {
    if (closeCallback != null) {
      await closeCallback!(uri);
    }
  }
}
