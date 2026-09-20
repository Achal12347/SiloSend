import 'dart:typed_data';

/// Standard IEEE 802.3 CRC32 implementation in pure Dart.
///
/// Used for packet integrity checking and chunk validation without external dependencies.
class Crc32 {
  Crc32._();

  static final Uint32List _table = _generateTable();

  static Uint32List _generateTable() {
    final table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        if ((c & 1) != 0) {
          c = (0xEDB88320 ^ (c >>> 1));
        } else {
          c = c >>> 1;
        }
      }
      table[i] = c;
    }
    return table;
  }

  /// Computes the 32-bit CRC checksum of [bytes].
  static int compute(List<int> bytes) {
    int crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = (crc >>> 8) ^ _table[(crc ^ b) & 0xFF];
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }
}
