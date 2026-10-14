import 'package:flutter/services.dart';

import 'package:vayu/core/security/secure_key_store.dart';

/// [SecureKeyStore] backed by the Android Keystore through SecureKeyStoreHandler.
///
/// The seed is wrapped by a hardware-held AES key on the native side; Dart only
/// sees the plaintext seed transiently while the session manager derives keys.
class AndroidSecureKeyStore implements SecureKeyStore {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/secure_key_store',
  );

  final MethodChannel channel;

  const AndroidSecureKeyStore({MethodChannel? channel})
    : channel = channel ?? _channel;

  @override
  Future<Uint8List?> loadIdentitySeed() async {
    final seed = await channel.invokeMethod<Uint8List>('load');
    if (seed == null || seed.length != 32) return null;
    return seed;
  }

  @override
  Future<void> saveIdentitySeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(
        seed.length,
        'seed',
        'Must be exactly 32 bytes',
      );
    }
    // Copy: the native side zeroes what it receives, not the caller's buffer.
    await channel.invokeMethod<bool>('save', {
      'seed': Uint8List.fromList(seed),
    });
  }

  @override
  Future<void> clearIdentitySeed() async {
    await channel.invokeMethod<bool>('clear');
  }
}
