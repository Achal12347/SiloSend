import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/file/system_storage_service.dart';

void main() {
  group('SystemStorageService Tests', () {
    late Directory tempDir;
    late SystemStorageService storageService;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('vayu_storage_test_');
      storageService = SystemStorageService(
        customDownloadsDirectory: tempDir.path,
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'getDownloadsDirectory ensures directory exists and returns valid path',
      () async {
        final path = await storageService.getDownloadsDirectory();
        expect(path, tempDir.path);
        expect(Directory(path).existsSync(), isTrue);
      },
    );

    test(
      'reserveDestinationPath returns original path when no collision',
      () async {
        final path = await storageService.reserveDestinationPath(
          tempDir.path,
          'document.pdf',
        );
        expect(path, '${tempDir.path}/document.pdf');
      },
    );

    test(
      'reserveDestinationPath disambiguates duplicate files with numbering',
      () async {
        // Create initial document.pdf
        File('${tempDir.path}/document.pdf')
            .writeAsStringSync('existing file 1');

        final firstDuplicate = await storageService.reserveDestinationPath(
          tempDir.path,
          'document.pdf',
        );
        expect(firstDuplicate, '${tempDir.path}/document (1).pdf');

        // Create document (1).pdf
        File(firstDuplicate).writeAsStringSync('existing file 2');

        final secondDuplicate = await storageService.reserveDestinationPath(
          tempDir.path,
          'document.pdf',
        );
        expect(secondDuplicate, '${tempDir.path}/document (2).pdf');
      },
    );

    test('reserveDestinationPath sanitizes path traversal attempts', () async {
      final malicious = '../../../../etc/shadow.txt';
      final path = await storageService.reserveDestinationPath(
        tempDir.path,
        malicious,
      );

      expect(path.contains('..'), isFalse);
      expect(path.startsWith(tempDir.path), isTrue);
    });

    test('reserveDestinationPath preserves Unicode names safely', () async {
      final path = await storageService.reserveDestinationPath(
        tempDir.path,
        '旅行写真.txt',
      );

      expect(path, '${tempDir.path}/旅行写真.txt');
      expect(path.startsWith(tempDir.path), isTrue);
    });

    test(
      'reserveDestinationPath handles very long names without escaping',
      () async {
        final longName = '${'a' * 300}.bin';
        final path = await storageService.reserveDestinationPath(
          tempDir.path,
          longName,
        );

        // 304 bytes cannot be a file name (255-byte limit, plus the staging
        // suffix): it is shortened before the extension and is creatable.
        final name = path.split(RegExp(r'[/\\]')).last;
        expect(path.startsWith(tempDir.path), isTrue);
        expect(name, endsWith('.bin'));
        expect(name, startsWith('aaaa'));
        expect(
          utf8.encode('$name (99).vayu.tmp').length,
          lessThanOrEqualTo(255),
        );
        expect(File('$path.vayu.tmp').existsSync(), isTrue);
      },
    );

    test('reserveDestinationPath strips Windows traversal segments', () async {
      final path = await storageService.reserveDestinationPath(
        tempDir.path,
        r'C:\Windows\System32\drivers\etc\hosts',
      );

      expect(path, '${tempDir.path}/hosts');
    });

    test('concurrent reservations of one name never share a path', () async {
      final paths = await Future.wait([
        for (var i = 0; i < 6; i++)
          storageService.reserveDestinationPath(tempDir.path, 'same.jpg'),
      ]);
      expect(paths.toSet(), hasLength(6));
      expect(paths, contains('${tempDir.path}/same.jpg'));
      expect(paths, contains('${tempDir.path}/same (5).jpg'));
      // Each reservation is its transfer's own staging file.
      for (final p in paths) {
        expect(File('$p.vayu.tmp').existsSync(), isTrue);
        expect(File(p).existsSync(), isFalse);
      }
    });

    test('a held staging file keeps its name reserved', () async {
      // A partial file kept for resume, or another running transfer.
      File('${tempDir.path}/clip.mp4.vayu.tmp').writeAsStringSync('partial');
      final path = await storageService.reserveDestinationPath(
        tempDir.path,
        'clip.mp4',
      );
      expect(path, '${tempDir.path}/clip (1).mp4');
      expect(
        File('${tempDir.path}/clip.mp4.vayu.tmp').readAsStringSync(),
        'partial',
      );
    });
  });
}
