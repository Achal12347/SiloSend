import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/utils/crc32.dart';

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
      final data1 = utf8.encode('SiloSend Offline Transfer');
      final data2 = utf8.encode('SiloSend Offline Transfer');
      expect(Crc32.compute(data1), equals(Crc32.compute(data2)));
    });

    test('detects single-bit differences in payload', () {
      final original = [1, 2, 3, 4, 5];
      final corrupted = [1, 2, 3, 4, 6];
      expect(Crc32.compute(original), isNot(equals(Crc32.compute(corrupted))));
    });
  });
}
