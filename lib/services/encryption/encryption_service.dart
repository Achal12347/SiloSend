import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class EncryptionService {
  static const int aesGcmNonceLength = 12;

  final AesGcm _aesGcm;

  EncryptionService({AesGcm? aesGcm})
    : _aesGcm = aesGcm ?? AesGcm.with256bits();

  SecretKey keyFromBytes(Uint8List bytes) {
    return SecretKey(bytes);
  }

  Future<Uint8List> generateNonce({
    required String transferId,
    required int chunkIndex,
  }) async {
    final input = utf8.encode('$transferId:$chunkIndex');
    final digest = sha256.convert(input).bytes;
    return Uint8List.fromList(
      digest.take(aesGcmNonceLength).toList(growable: false),
    );
  }

  Future<SecretBox> encryptBytes({
    required Uint8List plaintext,
    required SecretKey key,
    required Uint8List nonce,
    Uint8List? aad,
  }) {
    return _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad == null ? <int>[] : aad.toList(growable: false),
    );
  }

  Future<Uint8List> decryptBox({
    required SecretBox box,
    required SecretKey key,
    Uint8List? aad,
  }) async {
    final clear = await _aesGcm.decrypt(
      box,
      secretKey: key,
      aad: aad == null ? <int>[] : aad.toList(growable: false),
    );
    return Uint8List.fromList(clear);
  }

  Future<SecretBox> boxFromEncoded({
    required Uint8List cipherText,
    required Uint8List nonce,
    required Uint8List mac,
  }) async {
    return SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
  }

  Future<Uint8List> encodeBox(SecretBox box) async {
    return Uint8List.fromList(box.concatenation(nonce: false, mac: true));
  }
}
