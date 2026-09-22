import 'dart:typed_data';

import 'package:silosend_datasharing_app/core/security/sas_word_list.dart';

/// Represents a user-verifiable Short Authentication String (SAS).
///
/// Cryptographic & Security Properties:
/// - Derived deterministically from the 16-byte K_sas produced by HKDF-SHA256.
/// - Covers the full handshake transcript, ephemeral public keys, and nonces.
/// - Single-attempt collision probability: P_collision = 10^-6 (1 in 1,000,000).
/// - IMPORTANT: SAS does NOT automatically guarantee MITM protection; the manual
///   comparison performed by human users across an independent physical channel
///   is the actual authentication action.
class ShortAuthenticationString {
  /// Canonical 6-digit numeric string formatted with a central space, e.g. "582 194".
  final String numeric;

  /// Canonical 4-word biometric string, e.g. "amber falcon beacon river".
  final String words;

  const ShortAuthenticationString({required this.numeric, required this.words});

  /// Derives the [ShortAuthenticationString] from the 16-byte [sasKey] (K_sas).
  factory ShortAuthenticationString.fromKey(Uint8List sasKey) {
    if (sasKey.length != 16) {
      throw ArgumentError.value(
        sasKey.length,
        'sasKey',
        'SAS key must be exactly 16 bytes',
      );
    }

    // 1. 6-digit numeric SAS from bytes 0..3 (Big-Endian uint32)
    final v =
        ((sasKey[0] & 0xFF) << 24) |
        ((sasKey[1] & 0xFF) << 16) |
        ((sasKey[2] & 0xFF) << 8) |
        (sasKey[3] & 0xFF);

    // Unsigned 32-bit modulo 1,000,000
    final unsignedV = v & 0xFFFFFFFF;
    final n = unsignedV % 1000000;
    final p1 = (n ~/ 1000).toString().padLeft(3, '0');
    final p2 = (n % 1000).toString().padLeft(3, '0');
    final numeric = '$p1 $p2';

    // 2. 4-word SAS from bytes 4..7 (each byte 0..255 indexing sasWordList)
    final w1 = sasWordList[sasKey[4] & 0xFF];
    final w2 = sasWordList[sasKey[5] & 0xFF];
    final w3 = sasWordList[sasKey[6] & 0xFF];
    final w4 = sasWordList[sasKey[7] & 0xFF];
    final words = '$w1 $w2 $w3 $w4';

    return ShortAuthenticationString(numeric: numeric, words: words);
  }
}
