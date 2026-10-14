import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/security/aead_cipher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.achyrio.vayu/aead');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final dart = DartAeadCipher();

  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final nonce = Uint8List.fromList(List.generate(12, (i) => i + 100));
  final aad = Uint8List.fromList(List.generate(76, (i) => i * 2));
  final plain = Uint8List.fromList(List.generate(65536, (i) => i & 0xff));

  // Emulates the native handler: standard GCM returning ciphertext || tag.
  void installNativeEmulator() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final k = args['key'] as Uint8List;
      final n = args['nonce'] as Uint8List;
      final a = args['aad'] as Uint8List;
      final data = args['data'] as Uint8List;
      if (call.method == 'encrypt') {
        final r = await dart.encrypt(plaintext: data, key: k, nonce: n, aad: a);
        return Uint8List.fromList([...r.ciphertext, ...r.authTag]);
      }
      try {
        return await dart.decrypt(
          ciphertext: Uint8List.sublistView(data, 0, data.length - 16),
          authTag: Uint8List.sublistView(data, data.length - 16),
          key: k,
          nonce: n,
          aad: a,
        );
      } on SecretBoxAuthenticationError {
        throw PlatformException(code: 'AUTH_FAILED');
      }
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'platform output splits into the same ciphertext and tag as Dart',
    () async {
      installNativeEmulator();
      final platform = PlatformAeadCipher();
      final p = await platform.encrypt(
        plaintext: plain,
        key: key,
        nonce: nonce,
        aad: aad,
      );
      final d = await dart.encrypt(
        plaintext: plain,
        key: key,
        nonce: nonce,
        aad: aad,
      );
      expect(p.ciphertext, d.ciphertext);
      expect(p.authTag, d.authTag);

      final round = await platform.decrypt(
        ciphertext: p.ciphertext,
        authTag: p.authTag,
        key: key,
        nonce: nonce,
        aad: aad,
      );
      expect(round, plain);
    },
  );

  test(
    'tampered packets raise the same authentication error as Dart',
    () async {
      installNativeEmulator();
      final platform = PlatformAeadCipher();
      final sealed = await platform.encrypt(
        plaintext: plain,
        key: key,
        nonce: nonce,
        aad: aad,
      );
      final forged = Uint8List.fromList(sealed.ciphertext)..[10] ^= 0x01;
      await expectLater(
        platform.decrypt(
          ciphertext: forged,
          authTag: sealed.authTag,
          key: key,
          nonce: nonce,
          aad: aad,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    },
  );

  test('falls back to Dart when the native channel is absent', () async {
    final platform = PlatformAeadCipher();
    final p = await platform.encrypt(
      plaintext: plain,
      key: key,
      nonce: nonce,
      aad: aad,
    );
    final d = await dart.encrypt(
      plaintext: plain,
      key: key,
      nonce: nonce,
      aad: aad,
    );
    expect(p.ciphertext, d.ciphertext);
    expect(p.authTag, d.authTag);
  });
}
