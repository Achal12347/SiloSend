import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Phase 4 encryption scaffolding.
///
/// For now this service provides AES-GCM encrypt/decrypt primitives so the
/// upcoming File Transfer Engine can wrap encrypted chunk payloads.
///
/// No integration with transfer is done in Phase 4.
class EncryptionService {
  final AesGcm _aesGcm;

  EncryptionService({AesGcm? aesGcm})
    : _aesGcm = aesGcm ?? AesGcm.with256bits();

  /// Encrypts [plaintext] with a symmetric [key] and 12-byte [nonce].
  ///
  /// Returns ciphertext + authentication tag as produced by AES-GCM.
  Future<SecretBox> encrypt({
    required Uint8List plaintext,
    required SecretKey key,
    required Uint8List nonce,
    Uint8List? aad,
  }) {
    return _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad == null ? <int>[] : aad.toList(),
    );
  }

  /// Decrypts [ciphertext] using AES-GCM.
  Future<Uint8List> decrypt({
    required SecretBox box,
    required SecretKey key,
    Uint8List? aad,
  }) async {
    final clear = await _aesGcm.decrypt(
      box,
      secretKey: key,
      aad: aad == null ? <int>[] : aad.toList(),
    );
    return Uint8List.fromList(clear);
  }
}
