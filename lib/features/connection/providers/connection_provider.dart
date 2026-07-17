import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/models/device.dart';
import 'package:silosend/services/connection/p2p_connection_service.dart';

enum ConnectionStatus {
  initial,
  validating,
  connecting,
  connected,
  disconnecting,
  disconnected,
  error,
}

class ConnectionState {
  final ConnectionStatus status;
  final Device? device;
  final String? errorMessage;

  const ConnectionState({
    this.status = ConnectionStatus.initial,
    this.device,
    this.errorMessage,
  });

  ConnectionState copyWith({
    ConnectionStatus? status,
    Device? device,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ConnectionState(
      status: status ?? this.status,
      device: device ?? this.device,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class ConnectionNotifier extends StateNotifier<ConnectionState> {
  final P2pConnectionService service;

  ConnectionNotifier({required this.service}) : super(const ConnectionState());

  void setDevice(Device device) {
    state = state.copyWith(
      device: device,
      status: ConnectionStatus.initial,
      clearError: true,
    );
  }

  Future<void> connect() async {
    final device = state.device;
    if (device == null || device.id.isEmpty) return;

    state = state.copyWith(
      status: ConnectionStatus.validating,
      clearError: true,
    );

    try {
      await service.validateDevice(device);
      state = state.copyWith(status: ConnectionStatus.connecting);
      await service.connect(device);
      state = state.copyWith(status: ConnectionStatus.connected);
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> disconnect() async {
    state = state.copyWith(
      status: ConnectionStatus.disconnecting,
      clearError: true,
    );

    try {
      await service.disconnect();
      state = state.copyWith(status: ConnectionStatus.disconnected);
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> reconnect() async {
    final device = state.device;
    if (device == null || device.id.isEmpty) return;

    state = state.copyWith(
      status: ConnectionStatus.validating,
      clearError: true,
    );

    try {
      await service.reconnect(device);
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
    StateNotifierProvider.autoDispose<ConnectionNotifier, ConnectionState>((
      ref,
    ) {
      final service = P2pConnectionService();
      ref.onDispose(service.dispose);
      return ConnectionNotifier(service: service);
    });
