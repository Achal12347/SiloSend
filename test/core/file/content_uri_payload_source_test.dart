import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/domain/transfer/content_uri_payload_source.dart';

void main() {
  group('ContentUriPayloadSource Tests', () {
    late Uint8List testData;
    late String expectedSha256;
    bool wasClosed = false;

    setUp(() {
      testData = Uint8List.fromList(
        List.generate(150 * 1024, (i) => (i * 31 + 7) % 256),
      );
      expectedSha256 = crypto.sha256.convert(testData).toString();
      wasClosed = false;
    });

    ContentUriPayloadSource createSource() {
      return ContentUriPayloadSource(
        uri: 'content://com.android.providers.media.documents/document/image%3A123',
        length: testData.length,
        readChunkCallback: (uri, offset, length) async {
          final end = (offset + length).clamp(0, testData.length);
          return Uint8List.fromList(testData.sublist(offset, end));
        },
        closeCallback: (uri) async {
          wasClosed = true;
        },
      );
    }

    test('Exposes exact length and URI identifier', () {
      final source = createSource();
      expect(source.length, testData.length);
      expect(source.uri, contains('content://'));
    });

    test('readChunk reads precise slices across boundaries', () async {
      final source = createSource();

      final firstChunk = await source.readChunk(0, 1024);
      expect(firstChunk.length, 1024);
      expect(firstChunk, testData.sublist(0, 1024));

      final midChunk = await source.readChunk(5000, 2048);
      expect(midChunk.length, 2048);
      expect(midChunk, testData.sublist(5000, 7048));

      // End of file boundary clamping
      final endChunk = await source.readChunk(testData.length - 500, 1000);
      expect(endChunk.length, 500);
      expect(endChunk, testData.sublist(testData.length - 500));
    });

    test('readChunk throws RangeError on invalid negative offset', () async {
      final source = createSource();
      expect(() => source.readChunk(-1, 100), throwsRangeError);
    });

    test(
      'openStream yields sequential chunks without memory ballooning',
      () async {
        final source = createSource();
        final chunks = <Uint8List>[];

        await for (final chunk in source.openStream(chunkSize: 64 * 1024)) {
          chunks.add(chunk);
        }

        final reconstructed = Uint8List.fromList(
          chunks.expand((c) => c).toList(),
        );
        expect(reconstructed.length, testData.length);
        expect(reconstructed, testData);
      },
    );

    test(
      'computeSha256 matches cryptographic digest of underlying content',
      () async {
        final source = createSource();
        final computed = await source.computeSha256();
        expect(computed, expectedSha256);
      },
    );

    test(
      'computeSha256 resolves an unknown content length while streaming',
      () async {
        final source = ContentUriPayloadSource(
          uri: 'content://provider/unknown-size',
          length: -1,
          readChunkCallback: (uri, offset, length) async {
            if (offset >= testData.length) return Uint8List(0);
            final end = (offset + length).clamp(0, testData.length);
            return Uint8List.fromList(testData.sublist(offset, end));
          },
        );

        expect(source.length, -1);
        expect(await source.computeSha256(), expectedSha256);
        expect(source.length, testData.length);
      },
    );

    test('close calls closeCallback', () async {
      final source = createSource();
      expect(wasClosed, isFalse);
      await source.close();
      expect(wasClosed, isTrue);
    });
  });
}
