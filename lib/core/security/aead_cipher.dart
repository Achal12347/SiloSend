import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

/// AES-256-GCM primitive used by [CryptoService] for every session packet.
///
/// Both implementations produce standard GCM output, so a peer using one can
/// talk to a peer using the other.
abstract class AeadCipher {
  Future<({Uint8List ciphertext, Uint8List authTag})> encrypt({
    required Uint8List plaintext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  });

  /// Throws [SecretBoxAuthenticationError] when the tag does not verify.
  Future<Uint8List> decrypt({
    required Uint8List ciphertext,
    required Uint8List authTag,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  });
}

/// Portable pure-Dart cipher from package:cryptography (desktop, tests, fallback).
class DartAeadCipher implements AeadCipher {
  final AesGcm _aes = AesGcm.with256bits();

  @override
  Future<({Uint8List ciphertext, Uint8List authTag})> encrypt({
    required Uint8List plaintext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    final box = await _aes.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    return (
      ciphertext: Uint8List.fromList(box.cipherText),
      authTag: Uint8List.fromList(box.mac.bytes),
    );
  }

  @override
  Future<Uint8List> decrypt({
    required Uint8List ciphertext,
    required Uint8List authTag,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    final box = SecretBox(ciphertext, nonce: nonce, mac: Mac(authTag));
    return Uint8List.fromList(
      await _aes.decrypt(box, secretKey: SecretKey(key), aad: aad),
    );
  }
}

/// Android platform cipher (javax.crypto with hardware AES) on a background thread.
///
/// Falls back to [fallback] only when the native channel is missing, never after
/// an authentication failure, so a forged packet cannot be retried in Dart.
class PlatformAeadCipher implements AeadCipher {
  static const MethodChannel _channel = MethodChannel('com.achyrio.vayu/aead');
  static const int _tagLength = 16;

  final AeadCipher fallback;
  final MethodChannel channel;
  bool _platformMissing = false;

  PlatformAeadCipher({AeadCipher? fallback, MethodChannel? channel})
    : fallback = fallback ?? DartAeadCipher(),
      channel = channel ?? _channel;

  @override
  Future<({Uint8List ciphertext, Uint8List authTag})> encrypt({
    required Uint8List plaintext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    if (!_platformMissing) {
      try {
        final sealed = await channel.invokeMethod<Uint8List>('encrypt', {
          'key': key,
          'nonce': nonce,
          'aad': aad,
          'data': plaintext,
        });
        if (sealed != null && sealed.length >= _tagLength) {
          final split = sealed.length - _tagLength;
          return (
            ciphertext: Uint8List.sublistView(sealed, 0, split),
            authTag: Uint8List.sublistView(sealed, split),
          );
        }
        throw StateError('Platform cipher returned malformed output');
      } on MissingPluginException {
        _platformMissing = true;
      }
    }
    return fallback.encrypt(
      plaintext: plaintext,
      key: key,
      nonce: nonce,
      aad: aad,
    );
  }

  @override
  Future<Uint8List> decrypt({
    required Uint8List ciphertext,
    required Uint8List authTag,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) async {
    if (!_platformMissing) {
      final sealed = Uint8List(ciphertext.length + authTag.length)
        ..setRange(0, ciphertext.length, ciphertext)
        ..setRange(
          ciphertext.length,
          ciphertext.length + authTag.length,
          authTag,
        );
      try {
        final plain = await channel.invokeMethod<Uint8List>('decrypt', {
          'key': key,
          'nonce': nonce,
          'aad': aad,
          'data': sealed,
        });
        if (plain == null) {
          throw StateError('Platform cipher returned no plaintext');
        }
        return plain;
      } on MissingPluginException {
        _platformMissing = true;
      } on PlatformException catch (e) {
        if (e.code == 'AUTH_FAILED') {
          throw SecretBoxAuthenticationError();
        }
        rethrow;
      }
    }
    return fallback.decrypt(
      ciphertext: ciphertext,
      authTag: authTag,
      key: key,
      nonce: nonce,
      aad: aad,
    );
  }
}
