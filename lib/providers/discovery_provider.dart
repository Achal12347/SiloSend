import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../repositories/device_repository.dart';
import '../repositories/device_repository_mock.dart';

enum DiscoveryStatus { idle, loading, success, error }

class DiscoveryState {
  final DiscoveryStatus status;
  final List<Device> devices;
  final String? errorMessage;

  const DiscoveryState({
    required this.status,
    required this.devices,
    this.errorMessage,
  });

  const DiscoveryState.initial()
    : status = DiscoveryStatus.idle,
      devices = const [],
      errorMessage = null;

  DiscoveryState copyWith({
    DiscoveryStatus? status,
    List<Device>? devices,
    String? errorMessage,
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class DiscoveryNotifier extends StateNotifier<DiscoveryState> {
  final DeviceRepository _deviceRepository;

  DiscoveryNotifier({DeviceRepository? deviceRepository})
    : _deviceRepository = deviceRepository ?? MockDeviceRepository(),
      super(const DiscoveryState.initial());

  Future<void> startDiscovery() async {
    state = state.copyWith(status: DiscoveryStatus.loading, errorMessage: null);

    try {
      final devices = await _deviceRepository.discoverDevices();
      state = state.copyWith(
        status: DiscoveryStatus.success,
        devices: devices,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> refresh() => startDiscovery();
}

final discoveryProvider =
    StateNotifierProvider<DiscoveryNotifier, DiscoveryState>(
      (ref) => DiscoveryNotifier(),
    );
