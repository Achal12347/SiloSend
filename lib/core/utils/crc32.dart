import 'dart:typed_data';

/// Standard IEEE 802.3 CRC32 implementation in pure Dart.
///
/// Used for packet and chunk integrity checks. Every chunk is checksummed
/// twice on each phone (chunk and frame), so byte buffers use slicing-by-8:
/// the byte-at-a-time loop was the largest single cost of a transfer.
/// Results are identical to the byte-at-a-time algorithm.
class Crc32 {
  Crc32._();

  // Eight 256-entry tables in one list: table k at offset k * 256.
  static final Uint32List _tables = _generateTables();

  static Uint32List _generateTables() {
    final t = Uint32List(8 * 256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      t[i] = c;
    }
    for (int i = 0; i < 256; i++) {
      for (int k = 1; k < 8; k++) {
        final prev = t[(k - 1) * 256 + i];
        t[k * 256 + i] = (prev >>> 8) ^ t[prev & 0xFF];
      }
    }
    return t;
  }

  /// Computes the 32-bit CRC checksum of [bytes].
  static int compute(List<int> bytes) {
    if (bytes is Uint8List) return computeRange(bytes, 0, bytes.length);
    final t = _tables;
    int crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = (crc >>> 8) ^ t[(crc ^ b) & 0xFF];
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  /// CRC32 of `bytes[start, end)` without copying the range.
  static int computeRange(Uint8List bytes, int start, int end) {
    final t = _tables;
    int crc = 0xFFFFFFFF;
    int i = start;
    final last8 = end - 8;
    while (i <= last8) {
      final one =
          (bytes[i] |
              (bytes[i + 1] << 8) |
              (bytes[i + 2] << 16) |
              (bytes[i + 3] << 24)) ^
          crc;
      final two =
          bytes[i + 4] |
          (bytes[i + 5] << 8) |
          (bytes[i + 6] << 16) |
          (bytes[i + 7] << 24);
      crc =
          t[1792 + (one & 0xFF)] ^
          t[1536 + ((one >>> 8) & 0xFF)] ^
          t[1280 + ((one >>> 16) & 0xFF)] ^
          t[1024 + ((one >>> 24) & 0xFF)] ^
          t[768 + (two & 0xFF)] ^
          t[512 + ((two >>> 8) & 0xFF)] ^
          t[256 + ((two >>> 16) & 0xFF)] ^
          t[(two >>> 24) & 0xFF];
      i += 8;
    }
    while (i < end) {
      crc = (crc >>> 8) ^ t[(crc ^ bytes[i]) & 0xFF];
      i++;
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }
}
