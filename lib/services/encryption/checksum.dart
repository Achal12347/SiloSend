import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class Checksum {
  /// Returns a SHA-256 hex digest for [data].
  static String sha256Hex(Uint8List data) {
    final digest = sha256.convert(data);
    return digest.toString();
  }

  /// Validates that [expectedSha256Hex] matches the SHA-256 digest of [data].
  static bool validateSha256(Uint8List data, String expectedSha256Hex) {
    return sha256Hex(data).toLowerCase() ==
        expectedSha256Hex.trim().toLowerCase();
  }

  /// Utility for debugging (not used in transfer yet).
  static String toBase64(Uint8List data) => base64Encode(data);
}
