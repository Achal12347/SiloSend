import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/file/system_storage_service.dart';

void main() {
  group('SystemStorageService Tests', () {
    late Directory tempDir;
    late SystemStorageService storageService;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('silosend_storage_test_');
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
      'resolveUniqueDestinationPath returns original path when no collision',
      () async {
        final path = await storageService.resolveUniqueDestinationPath(
          tempDir.path,
          'document.pdf',
        );
        expect(path, '${tempDir.path}/document.pdf');
      },
    );

    test('resolveUniqueDestinationPath disambiguates duplicate files with numbering', () async {
      // Create initial document.pdf
      File('${tempDir.path}/document.pdf').writeAsStringSync('existing file 1');

      final firstDuplicate = await storageService.resolveUniqueDestinationPath(
        tempDir.path,
        'document.pdf',
      );
      expect(firstDuplicate, '${tempDir.path}/document (1).pdf');

      // Create document (1).pdf
      File(firstDuplicate).writeAsStringSync('existing file 2');

      final secondDuplicate = await storageService.resolveUniqueDestinationPath(
        tempDir.path,
        'document.pdf',
      );
      expect(secondDuplicate, '${tempDir.path}/document (2).pdf');
    });

    test(
      'resolveUniqueDestinationPath sanitizes path traversal attempts',
      () async {
        final malicious = '../../../../etc/shadow.txt';
        final path = await storageService.resolveUniqueDestinationPath(
          tempDir.path,
          malicious,
        );

        expect(path.contains('..'), isFalse);
        expect(path.startsWith(tempDir.path), isTrue);
      },
    );

    test(
      'resolveUniqueDestinationPath preserves Unicode names safely',
      () async {
        final path = await storageService.resolveUniqueDestinationPath(
          tempDir.path,
          '旅行写真.txt',
        );

        expect(path, '${tempDir.path}/旅行写真.txt');
        expect(path.startsWith(tempDir.path), isTrue);
      },
    );

    test(
      'resolveUniqueDestinationPath handles very long names without escaping',
      () async {
        final longName = '${'a' * 300}.bin';
        final path = await storageService.resolveUniqueDestinationPath(
          tempDir.path,
          longName,
        );

        expect(path.startsWith(tempDir.path), isTrue);
        expect(path.split(RegExp(r'[/\\]')).last, longName);
      },
    );

    test(
      'resolveUniqueDestinationPath strips Windows traversal segments',
      () async {
        final path = await storageService.resolveUniqueDestinationPath(
          tempDir.path,
          r'C:\Windows\System32\drivers\etc\hosts',
        );

        expect(path, '${tempDir.path}/hosts');
      },
    );
  });
}
