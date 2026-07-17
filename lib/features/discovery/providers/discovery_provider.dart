import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/models/device.dart';
import 'package:silosend/services/discovery/p2p_discovery_service.dart';

enum DiscoveryStatus { initial, searching, hosting, done, error }

class DiscoveryState {
  final DiscoveryStatus status;
  final List<Device> devices;
  final String? errorMessage;
  final bool isHosting;
  final String? hostSsid;
  final String? hostKey;

  const DiscoveryState({
    this.status = DiscoveryStatus.initial,
    this.devices = const [],
    this.errorMessage,
    this.isHosting = false,
    this.hostSsid,
    this.hostKey,
  });

  DiscoveryState copyWith({
    DiscoveryStatus? status,
    List<Device>? devices,
    String? errorMessage,
    bool? isHosting,
    String? hostSsid,
    String? hostKey,
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      errorMessage: errorMessage ?? this.errorMessage,
      isHosting: isHosting ?? this.isHosting,
      hostSsid: hostSsid ?? this.hostSsid,
      hostKey: hostKey ?? this.hostKey,
    );
  }
}

class DiscoveryNotifier extends StateNotifier<DiscoveryState> {
  final P2pDiscoveryService service;

  DiscoveryNotifier({required this.service}) : super(const DiscoveryState());

  Future<void> startDiscovery() async {
    if (state.status == DiscoveryStatus.searching) return;
    state = state.copyWith(status: DiscoveryStatus.searching, devices: []);
    try {
      final devices = await service.startDiscovery(
        onUpdate: (updatedDevices) {
          state = state.copyWith(
            status: DiscoveryStatus.done,
            devices: updatedDevices,
            errorMessage: null,
          );
        },
      );
      state = state.copyWith(status: DiscoveryStatus.done, devices: devices);
    } catch (e) {
      state = state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> startHosting() async {
    try {
      final hostState = await service.startHosting();
      state = state.copyWith(
        status: DiscoveryStatus.hosting,
        isHosting: hostState.isActive,
        hostSsid: hostState.ssid,
        hostKey: hostState.preSharedKey,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> stopHosting() async {
    try {
      await service.stopHosting();
      state = state.copyWith(
        status: DiscoveryStatus.initial,
        isHosting: false,
        hostSsid: null,
        hostKey: null,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> stopDiscovery() => service.stopDiscovery();
}

final discoveryProvider =
    StateNotifierProvider.autoDispose<DiscoveryNotifier, DiscoveryState>((ref) {
      final service = P2pDiscoveryService();
      ref.onDispose(service.dispose);
      return DiscoveryNotifier(service: service);
    });
