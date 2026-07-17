abstract class ConnectionRepository {
  Future<void> validateDevice(String deviceId);

  Future<void> connect(String deviceId);
  Future<void> disconnect(String deviceId);
  Future<void> reconnect(String deviceId);

  /// Throws on timeout/error (mock-only for Phase 3).
  Future<void> connectWithTimeout(String deviceId, Duration timeout);
}
