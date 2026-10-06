import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/session/session_lifecycle_policy.dart';

void main() {
  group('SessionLifecyclePolicy Tests', () {
    test('Keeps session alive while transfer is active and honors keepAliveAfterTransfer', () async {
      String? disconnectedSessionId;
      String? disconnectReason;

      final policy = SessionLifecyclePolicy(
        idleTimeout: const Duration(milliseconds: 50),
        postTransferGracePeriod: null,
        keepAliveAfterTransfer: true,
        onDisconnectSession: (sessionId, reason) async {
          disconnectedSessionId = sessionId;
          disconnectReason = reason;
        },
      );

      // 1. Mark transfer started
      policy.markTransferStarted('session-1');

      // Wait beyond the idle timeout duration
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Should NOT disconnect because transfer is active
      expect(disconnectedSessionId, isNull);

      // 2. Mark transfer ended
      policy.markTransferEnded('session-1');

      // Session should still be alive immediately after transfer
      expect(disconnectedSessionId, isNull);

      // Wait for idle timeout
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Now it should disconnect gracefully
      expect(disconnectedSessionId, 'session-1');
      expect(disconnectReason, contains('idle'));

      policy.dispose();
    });

    test(
      'Immediate disconnect policy when keepAliveAfterTransfer is false',
      () async {
        String? disconnectedSessionId;

        final policy = SessionLifecyclePolicy(
          idleTimeout: const Duration(minutes: 5),
          keepAliveAfterTransfer: false,
          onDisconnectSession: (sessionId, reason) async {
            disconnectedSessionId = sessionId;
          },
        );

        policy.markTransferStarted('session-2');
        policy.markTransferEnded('session-2');

        // Immediately disconnected
        expect(disconnectedSessionId, 'session-2');

        policy.dispose();
      },
    );

    test('recordActivity resets idle timer for multi-file transfers', () async {
      int disconnectCount = 0;

      final policy = SessionLifecyclePolicy(
        idleTimeout: const Duration(milliseconds: 60),
        postTransferGracePeriod: null,
        keepAliveAfterTransfer: true,
        onDisconnectSession: (sessionId, reason) async {
          disconnectCount++;
        },
      );

      policy.markTransferStarted('session-3');
      policy.markTransferEnded('session-3');

      // Sleep 35ms (not yet 60ms)
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(disconnectCount, 0);

      // User initiates another transfer (resets activity)
      policy.recordActivity('session-3');

      // Sleep another 35ms (total 70ms from end, but only 35ms from recordActivity)
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(disconnectCount, 0);

      // Sleep another 35ms (now > 60ms from last recordActivity)
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(disconnectCount, 1);

      policy.dispose();
    });

    test('Post-transfer grace period teardown disconnects after grace expires (R13)', () async {
      String? disconnectedSessionId;
      String? disconnectReason;

      final policy = SessionLifecyclePolicy(
        idleTimeout: const Duration(minutes: 3),
        postTransferGracePeriod: const Duration(milliseconds: 50),
        keepAliveAfterTransfer: true,
        onDisconnectSession: (sessionId, reason) async {
          disconnectedSessionId = sessionId;
          disconnectReason = reason;
        },
      );

      policy.markTransferStarted('session-grace-1');
      policy.markTransferEnded('session-grace-1');

      // Alive immediately after transfer ended
      expect(disconnectedSessionId, isNull);

      // Wait for grace period to expire
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(disconnectedSessionId, 'session-grace-1');
      expect(disconnectReason, contains('grace period'));
      expect(disconnectReason, contains('R13'));

      policy.dispose();
    });

    test('New transfer starting during post-transfer grace period cancels teardown (R13 & R14)', () async {
      int disconnectCount = 0;

      final policy = SessionLifecyclePolicy(
        idleTimeout: const Duration(minutes: 3),
        postTransferGracePeriod: const Duration(milliseconds: 50),
        keepAliveAfterTransfer: true,
        onDisconnectSession: (sessionId, reason) async {
          disconnectCount++;
        },
      );

      policy.markTransferStarted('session-grace-2');
      policy.markTransferEnded('session-grace-2');

      // Sleep 25ms (less than 50ms grace)
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(disconnectCount, 0);

      // Start new transfer (e.g. Share Again or pipelined transfer)
      policy.markTransferStarted('session-grace-2');

      // Wait beyond the original grace expiration
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(disconnectCount, 0); // Teardown was cancelled!

      policy.dispose();
    });
  });
}
