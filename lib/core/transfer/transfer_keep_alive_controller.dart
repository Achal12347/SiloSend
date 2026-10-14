import 'dart:async';

import 'package:vayu/core/contracts/transfer_keep_alive_contract.dart';

/// Reference-counts work that must survive screen-off and app switching.
///
/// Every send (including its pre-transfer hashing) and every accepted receive
/// holds one reference. The platform keep-alive starts on the first reference
/// and stops when the last one is released, so batches and concurrent
/// transfers share one foreground service.
class TransferKeepAliveController {
  final TransferKeepAlive keepAlive;

  /// Minimum gap between notification refreshes, to avoid flooding the platform.
  final Duration updateInterval;

  int _holders = 0;
  bool _askedNotifications = false;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _pending = Future.value();

  TransferKeepAliveController({
    required this.keepAlive,
    this.updateInterval = const Duration(seconds: 1),
  });

  /// Number of active holders, exposed for diagnostics and tests.
  int get holders => _holders;

  /// Acquires one reference and returns its single-use release callback.
  void Function() acquire({required String title, required String text}) {
    _holders++;
    if (_holders == 1) {
      _enqueue(() async {
        if (!_askedNotifications) {
          _askedNotifications = true;
          await keepAlive.requestNotificationPermission();
        }
        await keepAlive.start(title: title, text: text);
      });
    }

    var released = false;
    return () {
      if (released) return;
      released = true;
      _holders--;
      if (_holders == 0) {
        _enqueue(keepAlive.stop);
      }
    };
  }

  /// Refreshes the notification, throttled to [updateInterval].
  void report({required String title, required String text, int? progress}) {
    if (_holders == 0) return;
    final now = DateTime.now();
    if (now.difference(_lastUpdate) < updateInterval) return;
    _lastUpdate = now;
    _enqueue(
      () => keepAlive.update(title: title, text: text, progress: progress),
    );
  }

  // Platform calls run strictly in order so a fast stop can never overtake its start.
  void _enqueue(Future<void> Function() action) {
    _pending = _pending.then((_) => action()).catchError((_) {});
  }

  /// Waits for queued platform calls; used by tests and shutdown.
  Future<void> flush() => _pending;
}
