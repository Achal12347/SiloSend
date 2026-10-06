import 'dart:async';

import 'package:silosend_datasharing_app/core/logging/app_logger.dart';

/// Policy governing session retention after transfer completion and automatic
/// idle disconnection.
///
/// Keeps authenticated sessions alive so users can transfer multiple files sequentially
/// without re-negotiating handshakes, while gracefully closing connections and
/// securely wiping cryptographic keys after a configurable period of inactivity.
class SessionLifecyclePolicy {
  /// Inactivity duration before an idle session is automatically cleaned up.
  /// Set to `null` to disable automatic idle disconnect.
  final Duration? idleTimeout;

  /// Grace period after all transfers on a session have concluded before tearing down the session.
  ///
  /// Per SiloSend Real Device Integration Plan (R13), transfers have a ~5-second grace period
  /// after integrity verification before automatic session teardown and transport disconnect.
  /// Set to `null` to disable post-transfer grace teardown and use [idleTimeout] instead.
  final Duration? postTransferGracePeriod;

  /// Whether sessions should be kept alive after an individual transfer completes.
  final bool keepAliveAfterTransfer;

  final Future<void> Function(String sessionId, String reason)?
  onDisconnectSession;

  final Map<String, DateTime> _lastActivity = {};
  final Map<String, Timer> _idleTimers = {};
  final Map<String, Timer> _graceTimers = {};
  final Map<String, int> _activeTransferCounts = {};
  bool _isDisposed = false;

  SessionLifecyclePolicy({
    this.idleTimeout = const Duration(minutes: 3),
    this.postTransferGracePeriod = const Duration(seconds: 5),
    this.keepAliveAfterTransfer = true,
    this.onDisconnectSession,
  });

  /// Records fresh activity for [sessionId], resetting its idle countdown.
  void recordActivity(String sessionId) {
    if (_isDisposed) return;
    _lastActivity[sessionId] = DateTime.now();
    _resetTimer(sessionId);
  }

  /// Marks that a transfer is currently active on [sessionId].
  /// While a transfer is active, grace teardowns and idle timeouts are paused.
  void markTransferStarted(String sessionId) {
    _activeTransferCounts[sessionId] =
        (_activeTransferCounts[sessionId] ?? 0) + 1;
    _graceTimers.remove(sessionId)?.cancel();
    recordActivity(sessionId);
  }

  /// Marks that a transfer has concluded on [sessionId].
  ///
  /// Decrements active transfer counter. If no transfers remain on this session:
  /// Triggers immediate disconnect if [keepAliveAfterTransfer] is false.
  /// If true and [postTransferGracePeriod] is set, starts the ~5s teardown countdown (R13).
  /// Otherwise, falls back to the standard [idleTimeout].
  void markTransferEnded(String sessionId) {
    final count = _activeTransferCounts[sessionId] ?? 0;
    if (count > 1) {
      _activeTransferCounts[sessionId] = count - 1;
      recordActivity(sessionId);
      return;
    }
    _activeTransferCounts.remove(sessionId);

    if (!keepAliveAfterTransfer) {
      _executeDisconnect(
        sessionId,
        'Transfer completed (immediate disconnect policy)',
      );
    } else if (postTransferGracePeriod != null) {
      _startGraceTimer(sessionId);
    } else {
      recordActivity(sessionId);
    }
  }

  /// Manually unregisters and cleans up tracking for [sessionId].
  void unregisterSession(String sessionId) {
    _lastActivity.remove(sessionId);
    _activeTransferCounts.remove(sessionId);
    _idleTimers.remove(sessionId)?.cancel();
    _graceTimers.remove(sessionId)?.cancel();
  }

  void _startGraceTimer(String sessionId) {
    _graceTimers[sessionId]?.cancel();
    _idleTimers[sessionId]?.cancel();
    if (_isDisposed) return;

    AppLogger.info(
      'SessionLifecyclePolicy',
      'Transfer concluded on $sessionId; starting ${postTransferGracePeriod!.inSeconds}s grace teardown timer (R13)',
    );

    _graceTimers[sessionId] = Timer(postTransferGracePeriod!, () {
      if ((_activeTransferCounts[sessionId] ?? 0) > 0) {
        // Another transfer began during grace period; keep session alive
        return;
      }
      _executeDisconnect(
        sessionId,
        'Post-transfer grace period (~${postTransferGracePeriod!.inSeconds}s) expired (R13)',
      );
    });
  }

  void _resetTimer(String sessionId) {
    _idleTimers[sessionId]?.cancel();
    if (idleTimeout == null || _isDisposed) return;

    _idleTimers[sessionId] = Timer(idleTimeout!, () {
      if ((_activeTransferCounts[sessionId] ?? 0) > 0) {
        // Still has active transfer; do not disconnect
        _resetTimer(sessionId);
        return;
      }
      _executeDisconnect(
        sessionId,
        'Session idle for ${idleTimeout!.inSeconds}s',
      );
    });
  }

  void _executeDisconnect(String sessionId, String reason) {
    AppLogger.info(
      'SessionLifecyclePolicy',
      'Triggering session teardown for session $sessionId: $reason',
    );
    unregisterSession(sessionId);
    if (onDisconnectSession != null) {
      onDisconnectSession!(sessionId, reason).ignore();
    }
  }

  void dispose() {
    _isDisposed = true;
    for (final timer in _idleTimers.values) {
      timer.cancel();
    }
    for (final timer in _graceTimers.values) {
      timer.cancel();
    }
    _idleTimers.clear();
    _graceTimers.clear();
    _lastActivity.clear();
    _activeTransferCounts.clear();
  }
}
