import 'dart:math';

import 'connection_repository.dart';

class MockConnectionRepository implements ConnectionRepository {
  final Random _random;

  MockConnectionRepository({Random? random}) : _random = random ?? Random();

  @override
  Future<void> validateDevice(String deviceId) async {
    // Phase 3 mock-only validation.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (deviceId.isEmpty) {
      throw Exception('Device validation failed');
    }
  }

  @override
  Future<void> connect(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await validateDevice(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (deviceId.isEmpty) {
      throw Exception('Disconnect failed');
    }
  }

  @override
  Future<void> reconnect(String deviceId) async {
    // Disconnect + connect (mock)
    await disconnect(deviceId);
    await connect(deviceId);
  }

  @override
  Future<void> connectWithTimeout(String deviceId, Duration timeout) async {
    // Simulate connect and randomly either succeed or timeout.
    final simulated = Duration(milliseconds: 200 + _random.nextInt(700));
    if (simulated > timeout) {
      // Let this surface as a timeout-like error for Phase 3 UI.
      await Future<void>.delayed(timeout);
      throw Exception('Connection timed out');
    }

    await Future<void>.delayed(simulated);
    await connect(deviceId);
  }
}
