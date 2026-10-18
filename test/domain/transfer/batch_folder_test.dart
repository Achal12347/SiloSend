import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';

void main() {
  group('folder paths', () {
    String? clean(String? path) => BatchManifestEntry.sanitizeFolder(path);

    test('ordinary paths are kept', () {
      expect(clean('Trip'), 'Trip');
      expect(clean('Trip/2024/June'), 'Trip/2024/June');
      expect(clean(r'Trip\2024'), 'Trip/2024');
    });

    test('paths can never point outside the save folder', () {
      expect(clean('../../etc'), 'etc');
      expect(clean('/sdcard/Download'), 'sdcard/Download');
      expect(clean('a/./b/../c'), 'a/b/c');
      expect(clean('..'), isNull);
      expect(clean('...'), isNull);
      expect(clean(''), isNull);
      expect(clean(null), isNull);
    });

    test('characters Android storage rejects are replaced', () {
      expect(clean('Notes: 2024?'), 'Notes_ 2024_');
      expect(clean('tab\there'), 'tabhere');
      expect(clean('trailing. '), 'trailing');
    });

    test('depth is limited', () {
      final deep = List.generate(50, (i) => 'd$i').join('/');
      expect(
        clean(deep)!.split('/'),
        hasLength(BatchManifestEntry.maxFolderDepth),
      );
    });
  });

  group('manifest', () {
    test('the folder travels in the batch offer', () {
      final offer = TransferBatchOfferPayload(
        batchId: Uint8List(16),
        files: [
          BatchManifestEntry(
            fileName: 'a.jpg',
            sizeBytes: 3,
            mimeType: 'image/jpeg',
            folder: 'Trip/2024',
          ),
          BatchManifestEntry(
            fileName: 'b.txt',
            sizeBytes: 1,
            mimeType: 'text/plain',
          ),
        ],
      );
      final decoded = TransferBatchOfferPayload.fromBytes(offer.toBytes());
      expect(decoded.files[0].folder, 'Trip/2024');
      expect(decoded.files[1].folder, isNull);
    });

    test('a hostile folder is cleaned when the offer is read', () {
      final entry = BatchManifestEntry.fromJson({
        'n': 'x.bin',
        's': 1,
        'm': 'application/octet-stream',
        'p': '../../../data/data/com.achyrio.vayu',
      });
      expect(entry.folder, 'data/data/com.achyrio.vayu');
    });

    test('entries from older builds have no folder', () {
      final entry = BatchManifestEntry.fromJson({
        'n': 'x.bin',
        's': 1,
        'm': 'application/octet-stream',
      });
      expect(entry.folder, isNull);
      expect(entry.toJson().containsKey('p'), isFalse);
    });
  });
}
