import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/transfer/resumable_transfers.dart';

void main() {
  late Directory dir;
  late File index;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vayu_resume_');
    index = File('${dir.path}/resumable_transfers.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File staging(String name, int size) =>
      File('${dir.path}/$name${ResumableTransfers.stagingSuffix}')
        ..writeAsBytesSync(List.filled(size, 7));

  test('a partial file survives an app restart and can be resumed', () async {
    final file = staging('movie.mp4', 3000);
    final before = ResumableTransfers(indexFile: index);
    before.keep(
      'key-1',
      PartialTransfer(
        stagingPath: file.path,
        contiguousChunks: 3,
        contiguousBytes: 3000,
      ),
    );
    await before.saved;
    before.dispose();

    final after = ResumableTransfers(indexFile: index);
    await after.load();
    expect(after.keptPaths, {file.path});
    final partial = after.take('key-1')!;
    expect(partial.contiguousChunks, 3);
    expect(partial.contiguousBytes, 3000);
    await after.saved;
    // Taken: not offered again after another restart.
    final again = ResumableTransfers(indexFile: index);
    await again.load();
    expect(again.keptPaths, isEmpty);
    after.dispose();
    again.dispose();
  });

  test(
    'expired, missing or shortened partial files are dropped on load',
    () async {
      final expired = staging('old.bin', 100);
      final shortened = staging('short.bin', 10);
      index.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'partials': {
            'a': {
              'path': expired.path,
              'chunks': 1,
              'bytes': 100,
              'until': DateTime.now()
                  .subtract(const Duration(minutes: 1))
                  .millisecondsSinceEpoch,
            },
            'b': {
              'path': shortened.path,
              'chunks': 1,
              'bytes': 500,
              'until': DateTime.now()
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
            },
            'c': {
              'path': '${dir.path}/gone${ResumableTransfers.stagingSuffix}',
              'chunks': 1,
              'bytes': 1,
              'until': DateTime.now()
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch,
            },
          },
        }),
      );
      final r = ResumableTransfers(indexFile: index);
      await r.load();
      expect(r.keptPaths, isEmpty);
      expect(expired.existsSync(), isFalse);
      expect(shortened.existsSync(), isFalse);
      r.dispose();
    },
  );

  test('a changed list cannot make Vayu keep or delete other files', () async {
    final precious = File('${dir.path}/photo.jpg')..writeAsStringSync('mine');
    index.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'partials': {
          'x': {
            'path': precious.path,
            'chunks': 1,
            'bytes': 1,
            'until': DateTime.now()
                .subtract(const Duration(minutes: 1))
                .millisecondsSinceEpoch,
          },
        },
      }),
    );
    final r = ResumableTransfers(indexFile: index);
    await r.load();
    expect(r.keptPaths, isEmpty);
    expect(precious.readAsStringSync(), 'mine');
    r.dispose();
  });
}
