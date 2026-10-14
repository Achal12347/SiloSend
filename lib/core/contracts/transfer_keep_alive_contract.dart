/// Platform hook that keeps the app, CPU and network awake while transfers run.
///
/// On Android this is a foreground service holding a wake lock and Wi-Fi lock.
/// Without it the OS freezes the app when the screen turns off or the user
/// switches apps, and long transfers stall until they time out.
abstract class TransferKeepAlive {
  /// Enters the keep-alive state. Returns false when the platform refused,
  /// for example because the app was already in the background.
  Future<bool> start({
    required String title,
    required String text,
    int? progress,
  });

  /// Refreshes the visible status text and optional 0-100 progress.
  Future<void> update({
    required String title,
    required String text,
    int? progress,
  });

  /// Leaves the keep-alive state and releases every lock.
  Future<void> stop();

  /// Asks once for permission to show the progress notification (Android 13+).
  Future<bool> requestNotificationPermission();
}

/// Keep-alive used where the platform needs none (desktop, tests).
class NoopTransferKeepAlive implements TransferKeepAlive {
  const NoopTransferKeepAlive();

  @override
  Future<bool> start({
    required String title,
    required String text,
    int? progress,
  }) async => true;

  @override
  Future<void> update({
    required String title,
    required String text,
    int? progress,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool> requestNotificationPermission() async => true;
}
