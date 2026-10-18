import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/utils/crc32.dart';

void main() {
  group('Crc32 Tests', () {
    test('computes correct checksum for empty array', () {
      expect(Crc32.compute([]), equals(0x00000000));
    });

    test('computes standard IEEE 802.3 test vector "123456789"', () {
      final bytes = ascii.encode('123456789');
      // Standard CRC-32/ISO-HDLC result for "123456789" is 0xCBF43926 (3421780262)
      expect(Crc32.compute(bytes), equals(0xCBF43926));
    });

    test('computes consistent checksums for identical payloads', () {
      final data1 = utf8.encode('Vayu Offline Transfer');
      final data2 = utf8.encode('Vayu Offline Transfer');
      expect(Crc32.compute(data1), equals(Crc32.compute(data2)));
    });

    test('detects single-bit differences in payload', () {
      final original = [1, 2, 3, 4, 5];
      final corrupted = [1, 2, 3, 4, 6];
      expect(Crc32.compute(original), isNot(equals(Crc32.compute(corrupted))));
    });

    test('fast path matches the byte-at-a-time algorithm for any length', () {
      // Reference: the original table-driven loop.
      final table = List<int>.generate(256, (i) {
        var c = i;
        for (var k = 0; k < 8; k++) {
          c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        }
        return c;
      });
      int reference(List<int> bytes) {
        var crc = 0xFFFFFFFF;
        for (final b in bytes) {
          crc = (crc >>> 8) ^ table[(crc ^ b) & 0xFF];
        }
        return (crc ^ 0xFFFFFFFF) >>> 0;
      }

      final random = Random(7);
      final data = Uint8List.fromList(
        List<int>.generate(4099, (_) => random.nextInt(256)),
      );
      for (var length = 0; length < 70; length++) {
        for (var start = 0; start < 9; start++) {
          final slice = data.sublist(start, start + length);
          expect(Crc32.compute(slice), reference(slice));
          expect(
            Crc32.computeRange(data, start, start + length),
            reference(slice),
          );
        }
      }
      expect(Crc32.compute(data), reference(data));
      // List<int> (not Uint8List) input still works.
      expect(Crc32.compute(data.toList()), reference(data));
    });
  });
}
