import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';

import 'package:vayu/core/security/aead_cipher.dart';
import 'package:vayu/core/utils/crc32.dart';

/// One measured stage of receiving a file.
class SpeedTestResult {
  final String name;

  /// MB/s (10^6 bytes per second). Null when the stage could not run.
  final double? megabytesPerSecond;

  /// Why it could not run, or what it measured.
  final String note;

  const SpeedTestResult(this.name, this.megabytesPerSecond, this.note);

  String summary() => megabytesPerSecond == null
      ? '$name: not measured ($note)'
      : '$name: ${megabytesPerSecond!.toStringAsFixed(1)} MB/s ($note)';
}

/// Measures, on this phone, how fast each stage a received file goes
/// through can run on its own: storage writes, the streaming SHA-256 (Dart,
/// as the receiver uses it today), Android's own SHA-256, CRC32 and AES-GCM.
///
/// Compared with a transfer's timings it shows which stage limits the
/// speed. Every number is timed here; nothing is estimated. The test file is
/// written next to received files and always deleted.
class PhoneSpeedTest {
  /// Folder the test file is written to (where received files go).
  final String directory;
  final AeadCipher aead;

  /// Hashes a file with Android's SHA-256 (null where there is none).
  final Future<void> Function(String path)? nativeHashFile;

  /// Bytes written to storage.
  final int fileBytes;

  /// Bytes pushed through each in-memory stage.
  final int memoryBytes;

  static const int _chunk = 1024 * 1024;

  PhoneSpeedTest({
    required this.directory,
    required this.aead,
    this.nativeHashFile,
    this.fileBytes = 256 * _chunk,
    this.memoryBytes = 64 * _chunk,
  });

  /// Android's SHA-256 through the same channel the sender uses.
  static Future<void> Function(String path) androidHashFile() {
    const channel = MethodChannel('com.achyrio.vayu/file_io');
    return (path) async {
      await channel.invokeMapMethod<String, dynamic>('sha256', {
        'uri': Uri.file(path).toString(),
      });
    };
  }

  Future<List<SpeedTestResult>> run({int? freeBytes}) async {
    final results = <SpeedTestResult>[];
    final block = Uint8List(_chunk);
    final random = Random.secure();
    for (var i = 0; i < block.length; i++) {
      block[i] = random.nextInt(256);
    }

    // 1. Storage: sequential 1 MiB writes, then a flush to disk, as received
    // chunks are written.
    final file = File(
      '$directory${Platform.pathSeparator}.vayu-speedtest-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final enoughSpace =
        freeBytes == null || freeBytes > fileBytes + 64 * _chunk;
    if (!enoughSpace) {
      results.add(
        SpeedTestResult(
          'Storage write',
          null,
          'needs ${(fileBytes / 1e6).round() + 64} MB free',
        ),
      );
    }
    var wrote = false;
    try {
      if (enoughSpace) {
        await Directory(directory).create(recursive: true);
        final raf = await file.open(mode: FileMode.write);
        final clock = Stopwatch()..start();
        try {
          for (var written = 0; written < fileBytes; written += _chunk) {
            await raf.writeFrom(block);
          }
          await raf.flush();
        } finally {
          await raf.close();
        }
        clock.stop();
        wrote = true;
        results.add(
          SpeedTestResult(
            'Storage write',
            _rate(fileBytes, clock.elapsed),
            '${(fileBytes / 1e6).round()} MB to the receive folder',
          ),
        );
      }

      // 2. Android's SHA-256 (what the sender uses), over the file just
      // written. The file may still be in memory, so this is an upper bound.
      final native = nativeHashFile;
      if (native == null) {
        results.add(
          const SpeedTestResult(
            'SHA-256 (Android)',
            null,
            'not on this platform',
          ),
        );
      } else if (!wrote) {
        results.add(
          const SpeedTestResult('SHA-256 (Android)', null, 'no test file'),
        );
      } else {
        try {
          final clock = Stopwatch()..start();
          await native(file.path);
          results.add(
            SpeedTestResult(
              'SHA-256 (Android)',
              _rate(fileBytes, clock.elapsed),
              'used by the sender',
            ),
          );
        } catch (e) {
          results.add(SpeedTestResult('SHA-256 (Android)', null, '$e'));
        }
      }
    } catch (e) {
      results.add(SpeedTestResult('Storage write', null, '$e'));
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    // 3. Dart SHA-256 on a background isolate: the receiver's streaming
    // hash, which writes wait for when it falls behind.
    // Locals only: the isolate must not capture this object.
    final hashBytes = memoryBytes;
    final dartHashTime = await Isolate.run(() {
      final sink = _DigestSink();
      final hashing = crypto.sha256.startChunkedConversion(sink);
      final clock = Stopwatch()..start();
      for (var done = 0; done < hashBytes; done += _chunk) {
        hashing.add(block);
      }
      hashing.close();
      return clock.elapsedMicroseconds;
    });
    results.add(
      SpeedTestResult(
        'SHA-256 (Dart)',
        _rate(memoryBytes, Duration(microseconds: dartHashTime)),
        'used by the receiver',
      ),
    );

    // 4. CRC32 of every chunk (both sides).
    final crcClock = Stopwatch()..start();
    var crc = 0;
    for (var done = 0; done < memoryBytes; done += _chunk) {
      crc ^= Crc32.compute(block);
    }
    crcClock.stop();
    results.add(
      SpeedTestResult(
        'CRC32',
        _rate(memoryBytes, crcClock.elapsed),
        'per chunk, both phones (check ${crc.toRadixString(16)})',
      ),
    );

    // 5. AES-256-GCM of 1 MiB packets, as every chunk is encrypted.
    final key = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final aad = Uint8List(76);
    try {
      final clock = Stopwatch()..start();
      for (var i = 0; i * _chunk < memoryBytes; i++) {
        final nonce = Uint8List(12)..buffer.asByteData().setUint64(4, i);
        await aead.encrypt(plaintext: block, key: key, nonce: nonce, aad: aad);
      }
      results.add(
        SpeedTestResult(
          'AES-GCM',
          _rate(memoryBytes, clock.elapsed),
          'encrypting 1 MiB packets',
        ),
      );
    } catch (e) {
      results.add(SpeedTestResult('AES-GCM', null, '$e'));
    }
    return results;
  }

  static double _rate(int bytes, Duration time) {
    final seconds = time.inMicroseconds / 1e6;
    return seconds > 0 ? bytes / 1e6 / seconds : 0;
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  @override
  void add(crypto.Digest data) {}

  @override
  void close() {}
}
