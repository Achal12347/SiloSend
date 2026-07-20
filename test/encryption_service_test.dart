import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend/services/encryption/encryption_service.dart';
import 'package:silosend/services/encryption/key_exchange.dart';

void main() {
  test('encrypts and decrypts bytes with the same key and nonce', () async {
    final service = EncryptionService();
    final key = service.keyFromBytes(
      Uint8List.fromList(List<int>.filled(32, 7)),
    );
    final nonce = Uint8List.fromList(List<int>.generate(12, (i) => i));
    final plaintext = Uint8List.fromList(
      utf8.encode('offline transfer payload'),
    );

    final box = await service.encryptBytes(
      plaintext: plaintext,
      key: key,
      nonce: nonce,
    );
    final clear = await service.decryptBox(box: box, key: key);

    expect(clear, plaintext);
  });

  test('derives unique nonce bytes from transfer and chunk index', () async {
    final service = EncryptionService();
    final first = await service.generateNonce(transferId: 'a', chunkIndex: 0);
    final second = await service.generateNonce(transferId: 'a', chunkIndex: 1);

    expect(first, isNot(equals(second)));
    expect(first.length, EncryptionService.aesGcmNonceLength);
  });

  test('generates session keys with the expected length', () {
    final keyExchange = KeyExchange();
    final key = keyExchange.generateSessionKey();

    expect(key.length, 32);
  });
}
