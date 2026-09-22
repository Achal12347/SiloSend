import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Represents a persistent local or remote Ed25519 cryptographic identity keypair.
///
/// Used exclusively for identity verification, proof of possession,
/// and digital signatures. It is strictly distinct from ephemeral Diffie-Hellman keys.
class CryptoIdentityKeypair {
  /// Exactly 32 bytes representing the compressed Edwards-curve public key.
  final Uint8List publicKey;

  /// Exactly 32 bytes representing the private seed, or null if representing a remote peer.
  final Uint8List? privateKeySeed;

  CryptoIdentityKeypair({required this.publicKey, this.privateKeySeed}) {
    if (publicKey.length != 32) {
      throw ArgumentError.value(
        publicKey.length,
        'publicKey',
        'Ed25519 public key must be exactly 32 bytes',
      );
    }
    if (privateKeySeed != null && privateKeySeed!.length != 32) {
      throw ArgumentError.value(
        privateKeySeed!.length,
        'privateKeySeed',
        'Ed25519 private key seed must be exactly 32 bytes if provided',
      );
    }
  }

  /// Derives the canonical 32-byte public key fingerprint:
  /// SHA-256("SiloSend-Ed25519-Identity-v1:" || publicKey)
  Uint8List get fingerprint {
    final prefix = 'SiloSend-Ed25519-Identity-v1:'.codeUnits;
    final buffer = Uint8List(prefix.length + publicKey.length);
    buffer.setRange(0, prefix.length, prefix);
    buffer.setRange(prefix.length, buffer.length, publicKey);

    final digest = crypto.sha256.convert(buffer);
    return Uint8List.fromList(digest.bytes);
  }

  /// Formatted 64-character uppercase hex string of the fingerprint.
  String get fingerprintHex => fingerprint
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();

  /// Canonical human-readable fingerprint formatted in 4-character blocks separated by colons.
  String get formattedFingerprint {
    final hex = fingerprintHex;
    final blocks = <String>[];
    for (int i = 0; i < hex.length; i += 4) {
      blocks.add(hex.substring(i, i + 4));
    }
    return blocks.join(':');
  }

  /// Canonical prefixed fingerprint string: `SiloSend-Ed25519-Identity-v1:<HEX>`
  String get canonicalFingerprint =>
      'SiloSend-Ed25519-Identity-v1:$fingerprintHex';

  /// Formats public key as a 64-character lowercase hex string.
  String get publicKeyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Creates a public-only representation from a 32-byte public key buffer.
  factory CryptoIdentityKeypair.fromPublicKey(Uint8List publicKey) {
    return CryptoIdentityKeypair(publicKey: Uint8List.fromList(publicKey));
  }

  /// Creates a public-only representation from a 64-character hex string.
  factory CryptoIdentityKeypair.fromPublicKeyHex(String hex) {
    if (hex.length != 64) {
      throw FormatException(
        'Invalid Ed25519 public key hex length: expected 64, got ${hex.length}',
      );
    }
    final bytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return CryptoIdentityKeypair(publicKey: bytes);
  }
}
