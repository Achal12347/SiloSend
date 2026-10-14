import 'dart:io';
import 'dart:isolate';

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
