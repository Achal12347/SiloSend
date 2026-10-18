import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/diagnostics/phone_speed_test.dart';
import 'package:vayu/core/security/aead_cipher.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('vayu_speed'));
  tearDown(() => dir.deleteSync(recursive: true));

  PhoneSpeedTest small({Future<void> Function(String)? nativeHashFile}) =>
      PhoneSpeedTest(
        directory: dir.path,
        aead: DartAeadCipher(),
        nativeHashFile: nativeHashFile,
        fileBytes: 4 * 1024 * 1024,
        memoryBytes: 2 * 1024 * 1024,
      );

  test('measures every stage and leaves no test file behind', () async {
    final hashed = <String>[];
    final results = await small(
      nativeHashFile: (path) async {
        // The file exists while it is hashed.
        expect(File(path).lengthSync(), 4 * 1024 * 1024);
        hashed.add(path);
      },
    ).run();

    expect(results.map((r) => r.name), [
      'Storage write',
      'SHA-256 (Android)',
      'SHA-256 (Dart)',
      'CRC32',
      'AES-GCM',
    ]);
    for (final r in results) {
      expect(r.megabytesPerSecond, isNotNull, reason: r.summary());
      expect(r.megabytesPerSecond, greaterThan(0), reason: r.summary());
    }
    expect(hashed, hasLength(1));
    expect(dir.listSync(), isEmpty);
  });

  test('without enough free space it writes nothing and says why', () async {
    final results = await small().run(freeBytes: 1024);
    final write = results.firstWhere((r) => r.name == 'Storage write');
    expect(write.megabytesPerSecond, isNull);
    expect(write.note, contains('free'));
    expect(dir.listSync(), isEmpty);
    // The in-memory stages still run.
    expect(
      results.firstWhere((r) => r.name == 'SHA-256 (Dart)').megabytesPerSecond,
      isNotNull,
    );
  });

  test('platforms without Android hashing report it as not measured', () async {
    final results = await small().run();
    final native = results.firstWhere((r) => r.name == 'SHA-256 (Android)');
    expect(native.megabytesPerSecond, isNull);
    expect(native.summary(), contains('not measured'));
  });
}
