import 'package:flutter/services.dart';

import 'package:vayu/core/security/local_data_sealer.dart';

/// [LocalDataSealer] using a non-exportable AES-256-GCM key in the Android
/// Keystore (SecureKeyStoreHandler, its own key alias). Runs on the
/// handler's background queue.
class AndroidLocalDataSealer implements LocalDataSealer {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/secure_key_store',
  );

  final MethodChannel channel;

  const AndroidLocalDataSealer({MethodChannel? channel})
    : channel = channel ?? _channel;

  @override
  Future<Uint8List> seal(Uint8List data, {required Uint8List aad}) async {
    final blob = await channel.invokeMethod<Uint8List>('seal', {
      'data': data,
      'aad': aad,
    });
    if (blob == null) throw StateError('Sealing returned nothing');
    return blob;
  }

  @override
  Future<Uint8List> open(Uint8List blob, {required Uint8List aad}) async {
    final data = await channel.invokeMethod<Uint8List>('open', {
      'blob': blob,
      'aad': aad,
    });
    if (data == null) throw StateError('Opening returned nothing');
    return data;
  }
}
