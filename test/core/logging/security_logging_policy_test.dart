import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/logging/security_logging_policy.dart';

void main() {
  group('SecurityLoggingPolicy Tests', () {
    test('redacts private keys, seeds, and secrets in log messages', () {
      const msg1 =
          'Generated keypair: privateKeySeed: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final sanitized1 = SecurityLoggingPolicy.sanitize(msg1);
      expect(sanitized1, contains('privateKeySeed: [REDACTED_SECRET]'));
      expect(sanitized1, isNot(contains('0123456789abcdef')));

      const msg2 =
          'Derived session keys: txKey=aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899, rxKey: 1122334455';
      final sanitized2 = SecurityLoggingPolicy.sanitize(msg2);
      expect(sanitized2, contains('txKey: [REDACTED_SECRET]'));
      expect(sanitized2, contains('rxKey: [REDACTED_SECRET]'));

      const msg3 = 'ECDH completed: sharedSecret: 99887766554433221100';
      final sanitized3 = SecurityLoggingPolicy.sanitize(msg3);
      expect(sanitized3, contains('sharedSecret: [REDACTED_SECRET]'));
    });

    test('preserves public fingerprints, sequence counters, and state names', () {
      const msg =
          'Session session-123 transitioned to SessionState.secured at seq 42 with fingerprint Vayu-Ed25519-Identity-v1:a1b2c3d4e5f6';
      final sanitized = SecurityLoggingPolicy.sanitize(msg);
      expect(sanitized, equals(msg));
    });

    test('containsSensitivePatterns correctly flags sensitive labels', () {
      expect(
        SecurityLoggingPolicy.containsSensitivePatterns('privateKey: secret'),
        isTrue,
      );
      expect(
        SecurityLoggingPolicy.containsSensitivePatterns('sharedSecret: ecdh'),
        isTrue,
      );
      expect(
        SecurityLoggingPolicy.containsSensitivePatterns('confirmKey: hmac'),
        isTrue,
      );
      expect(
        SecurityLoggingPolicy.containsSensitivePatterns(
          'Public fingerprint Vayu-Ed25519-Identity-v1:abc',
        ),
        isFalse,
      );
      expect(
        SecurityLoggingPolicy.containsSensitivePatterns('Packet sequence: 10'),
        isFalse,
      );
    });

    test('formatPublicFingerprint truncates safely', () {
      const fp = 'Vayu-Ed25519-Identity-v1:abcdef1234567890abcdef1234567890';
      final truncated = SecurityLoggingPolicy.formatPublicFingerprint(
        fp,
        prefixLength: 20,
      );
      expect(truncated, equals('Vayu-Ed25519-Identit...'));
      expect(
        SecurityLoggingPolicy.formatPublicFingerprint(
          'short',
          prefixLength: 20,
        ),
        equals('short'),
      );
    });

    test(
      'AppLogger passes log messages through sanitization without throwing',
      () {
        expect(
          () => AppLogger.info(
            'TestTag',
            'Testing privateKeySeed: secret123456 and public key fingerprint 1234',
          ),
          returnsNormally,
        );
        expect(
          () => AppLogger.debug('TestTag', 'Testing debug txKey: secret123456'),
          returnsNormally,
        );
        expect(
          () => AppLogger.warning(
            'TestTag',
            'Testing warning confirmKey: secret123456',
          ),
          returnsNormally,
        );
        expect(
          () => AppLogger.error(
            'TestTag',
            'Testing error sharedSecret: secret123456',
          ),
          returnsNormally,
        );
      },
    );
  });
}
