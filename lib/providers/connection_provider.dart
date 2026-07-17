import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/connection/connection_manager.dart';

enum ConnectionStatus {
  idle,
  validating,
  connecting,
  connected,
  disconnecting,
  error,
}

class ConnectionState {
  final ConnectionStatus status;
  final String? deviceId;
  final String? errorMessage;

  const ConnectionState({
    required this.status,
    this.deviceId,
    this.errorMessage,
  });

  const ConnectionState.initial()
    : status = ConnectionStatus.idle,
      deviceId = null,
      errorMessage = null;

  ConnectionState copyWith({
    ConnectionStatus? status,
    String? deviceId,
    String? errorMessage,
  }) {
    return ConnectionState(
      status: status ?? this.status,
      deviceId: deviceId ?? this.deviceId,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class ConnectionNotifier extends StateNotifier<ConnectionState> {
  final ConnectionManager _connectionManager;

  ConnectionNotifier({ConnectionManager? connectionManager})
    : _connectionManager = connectionManager ?? ConnectionManager(),
      super(const ConnectionState.initial());

  Future<void> setDevice(String deviceId) async {
    // Only validates in Phase 3 (mock-only).
    state = state.copyWith(
      status: ConnectionStatus.validating,
      deviceId: deviceId,
      errorMessage: null,
    );

    try {
      await _connectionManager.validateDevice(deviceId);
      state = state.copyWith(status: ConnectionStatus.idle, deviceId: deviceId);
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> connect() async {
    if (state.deviceId == null) return;

    state = state.copyWith(
      status: ConnectionStatus.connecting,
      errorMessage: null,
    );

    try {
      await _connectionManager.connectWithTimeout(
        state.deviceId!,
        timeout: const Duration(seconds: 1),
      );
      state = state.copyWith(status: ConnectionStatus.connected);
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> disconnect() async {
    if (state.deviceId == null) return;

    state = state.copyWith(
      status: ConnectionStatus.disconnecting,
      errorMessage: null,
    );

    try {
      await _connectionManager.disconnect(state.deviceId!);
      state = state.copyWith(status: ConnectionStatus.idle);
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> reconnect() async {
    if (state.deviceId == null) return;

    state = state.copyWith(
      status: ConnectionStatus.connecting,
      errorMessage: null,
    );

    try {
      await _connectionManager.reconnect(state.deviceId!);
      state = state.copyWith(status: ConnectionStatus.connected);
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
    }
  }
}

final connectionProvider =
    StateNotifierProvider<ConnectionNotifier, ConnectionState>(
      (ref) => ConnectionNotifier(),
    );
