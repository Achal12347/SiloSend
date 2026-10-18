import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Hashes a file with SHA-256 on a background isolate.
///
/// Whole-file hashing of a large transfer takes seconds; on the UI isolate it
/// froze rendering and delayed the ACK and keepalive timers sharing that isolate.
/// Shared by outbound file sources and the receiver's final verification.
Future<String> sha256OfFile(String path, {int? length}) {
  return Isolate.run(() async {
    final stream = File(path).openRead(0, length);
    final digest = await crypto.sha256.bind(stream).first;
    return digest.toString();
  });
}

/// SHA-256 computed on a background isolate while data streams in.
///
/// The receiver feeds each chunk as it is written, so the digest is ready
/// when the last chunk lands instead of after re-reading the whole file
/// (seconds per gigabyte on a phone, while the sender waits).
class BackgroundSha256 {
  final ReceivePort _results = ReceivePort();
  final Completer<SendPort> _input = Completer<SendPort>();
  final Completer<String> _digest = Completer<String>();
  Future<void> _sends = Future<void>.value();
  bool _closed = false;

  /// Bytes handed over but not yet hashed. On slow phones the network can
  /// outrun hashing; without a limit the copies queued here until the app
  /// ran out of memory on multi-gigabyte files.
  static const int maxBacklogBytes = 8 * 1024 * 1024;
  int _backlog = 0;
  Completer<void>? _drained;

  BackgroundSha256() {
    _results.listen((message) {
      if (message is int) {
        _backlog -= message;
        if (_backlog <= maxBacklogBytes) _releaseWaiter();
      } else if (message is SendPort) {
        _input.complete(message);
      } else if (message is String) {
        if (!_digest.isCompleted) _digest.complete(message);
        _releaseWaiter();
        _results.close();
      } else if (message == null) {
        // The worker exited without a digest (crashed or was killed):
        // release the writer; verification then re-reads the file.
        if (!_digest.isCompleted) {
          _digest.completeError(StateError('Hash worker stopped'));
        }
        _releaseWaiter();
        _results.close();
      }
    });
    Isolate.spawn(
      _hashWorker,
      _results.sendPort,
      errorsAreFatal: true,
      onExit: _results.sendPort,
    ).then(
      (_) {},
      onError: (Object e) {
        if (!_input.isCompleted) _input.completeError(e);
        if (!_digest.isCompleted) _digest.completeError(e);
        _releaseWaiter();
        _results.close();
      },
    );
    _digest.future.ignore();
  }

  void _releaseWaiter() {
    final waiting = _drained;
    _drained = null;
    waiting?.complete();
  }

  /// Adds the next bytes, in order. [data] is copied before this returns.
  /// The returned future completes once the backlog is small enough for the
  /// caller to go on; waiting on it keeps memory bounded.
  Future<void> add(Uint8List data) {
    if (_closed) throw StateError('BackgroundSha256 is closed');
    final copy = TransferableTypedData.fromList([data]);
    _backlog += data.length;
    _sends = _sends.then((_) async => (await _input.future).send(copy));
    if (_backlog <= maxBacklogBytes || _digest.isCompleted) {
      return Future<void>.value();
    }
    return (_drained ??= Completer<void>()).future;
  }

  /// Hex digest of everything added.
  Future<String> digest() {
    if (!_closed) {
      _closed = true;
      _sends = _sends.then((_) async => (await _input.future).send(null));
    }
    return _digest.future;
  }

  /// Stops the worker without a result (cancelled or abandoned transfer).
  void dispose() {
    if (_closed && _digest.isCompleted) return;
    _closed = true;
    // The worker exits on `false`; the port closes once it got the message.
    _sends = _sends
        .then((_) async => (await _input.future).send(false))
        .whenComplete(_results.close);
    _sends.ignore();
    if (!_digest.isCompleted) {
      _digest.completeError(StateError('BackgroundSha256 disposed'));
    }
    _releaseWaiter();
  }

  static void _hashWorker(SendPort results) {
    final input = ReceivePort();
    results.send(input.sendPort);
    final sink = _DigestSink();
    final hashing = crypto.sha256.startChunkedConversion(sink);
    input.listen((message) {
      if (message is TransferableTypedData) {
        final bytes = message.materialize().asUint8List();
        hashing.add(bytes);
        results.send(bytes.length);
      } else {
        if (message == null) {
          hashing.close();
          results.send(sink.value.toString());
        }
        input.close();
      }
    });
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
