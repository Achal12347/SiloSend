import '../../repositories/connection_repository.dart';
import '../../repositories/connection_repository_mock.dart';

class ConnectionManager {
  final ConnectionRepository _repository;

  ConnectionManager({ConnectionRepository? repository})
    : _repository = repository ?? MockConnectionRepository();

  /// Mock validation step (Phase 3 device validation).
  Future<void> validateDevice(String deviceId) async {
    await _repository.validateDevice(deviceId);
  }

  Future<void> connect(String deviceId) => _repository.connect(deviceId);
  Future<void> disconnect(String deviceId) => _repository.disconnect(deviceId);
  Future<void> reconnect(String deviceId) => _repository.reconnect(deviceId);

  Future<void> connectWithTimeout(
    String deviceId, {
    required Duration timeout,
  }) {
    return _repository.connectWithTimeout(deviceId, timeout);
  }
}
