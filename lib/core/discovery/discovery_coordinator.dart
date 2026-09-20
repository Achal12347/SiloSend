import 'dart:async';

import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/logging/app_logger.dart';

/// Coordinates peer discovery across multiple physical transports (LAN, BLE).
///
/// Core Responsibilities:
/// - Deduplicates peers by their 16-byte `deviceId`.
/// - Merges observed transports into a unified capability set (e.g. `{lan, ble}`).
/// - Automatically expires stale peers that have not transmitted a beacon within [staleTimeout].
/// - Emits reactive lists of active nearby peers and operational status.
class DiscoveryCoordinator {
  final List<DiscoveryService> services;
  final Duration staleTimeout;
  final Duration reaperInterval;

  final Map<String, DiscoveredPeer> _discoveredPeers = {};
  final List<StreamSubscription> _subscriptions = [];

  final _peersController = StreamController<List<DiscoveredPeer>>.broadcast();
  final _statusController = StreamController<DiscoveryStatus>.broadcast();

  Timer? _reaperTimer;
  DiscoveryStatus _status = DiscoveryStatus.idle;

  DiscoveryCoordinator({
    required this.services,
    this.staleTimeout = const Duration(seconds: 12),
    this.reaperInterval = const Duration(seconds: 3),
  }) {
    _attachServiceListeners();
  }

  /// Current list of active nearby peers.
  List<DiscoveredPeer> get currentPeers =>
      List.unmodifiable(_discoveredPeers.values);

  /// Reactive stream of currently active discovered peers.
  Stream<List<DiscoveredPeer>> get peersStream => _peersController.stream;

  /// Current operational status.
  DiscoveryStatus get status => _status;

  /// Reactive stream of operational status transitions.
  Stream<DiscoveryStatus> get statusStream => _statusController.stream;

  /// Starts discovery scanning across all configured transport services.
  Future<void> startDiscovery() async {
    if (_status == DiscoveryStatus.active) return;

    _updateStatus(DiscoveryStatus.starting);
    AppLogger.info(
      'DiscoveryCoordinator',
      'Starting multi-transport discovery...',
    );

    try {
      await Future.wait(services.map((s) => s.startDiscovery()));
      _startReaper();
      _updateStatus(DiscoveryStatus.active);
      AppLogger.info(
        'DiscoveryCoordinator',
        'Multi-transport discovery active',
      );
    } catch (e, stack) {
      _updateStatus(DiscoveryStatus.error);
      AppLogger.error(
        'DiscoveryCoordinator',
        'Failed to start discovery',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Stops discovery scanning across all services.
  Future<void> stopDiscovery() async {
    if (_status == DiscoveryStatus.idle) return;

    _updateStatus(DiscoveryStatus.stopping);
    AppLogger.info(
      'DiscoveryCoordinator',
      'Stopping multi-transport discovery...',
    );

    _stopReaper();
    await Future.wait(services.map((s) => s.stopDiscovery()));
    _discoveredPeers.clear();
    _peersController.add([]);
    _updateStatus(DiscoveryStatus.idle);
    AppLogger.info('DiscoveryCoordinator', 'Multi-transport discovery stopped');
  }

  /// Starts advertising local presence across all supported transports.
  Future<void> startAdvertising(DeviceAdvertisement advertisement) async {
    AppLogger.info(
      'DiscoveryCoordinator',
      'Starting multi-transport advertising...',
    );
    await Future.wait(services.map((s) => s.startAdvertising(advertisement)));
  }

  /// Stops advertising local presence across all transports.
  Future<void> stopAdvertising() async {
    AppLogger.info(
      'DiscoveryCoordinator',
      'Stopping multi-transport advertising...',
    );
    await Future.wait(services.map((s) => s.stopAdvertising()));
  }

  void _attachServiceListeners() {
    for (final service in services) {
      final sub = service.discoveredPeers.listen(
        _handleDiscoveredPeer,
        onError: (e) {
          AppLogger.error(
            'DiscoveryCoordinator',
            'Error in discovery service ${service.transportType}',
            error: e,
          );
        },
      );
      _subscriptions.add(sub);
    }
  }

  void _handleDiscoveredPeer(DiscoveredPeer incoming) {
    final key = incoming.deviceId.toLowerCase();
    final existing = _discoveredPeers[key];

    if (existing == null) {
      // Fresh peer
      _discoveredPeers[key] = incoming;
      AppLogger.debug(
        'DiscoveryCoordinator',
        'Discovered new peer: ${incoming.displayName} (${incoming.transportType})',
      );
    } else {
      // Deduplication & Capability Merging:
      // Merge transport sets e.g. {lan} + {ble} -> {lan, ble}
      final mergedTransports =
          Set<TransportType>.from(existing.availableTransports)
            ..addAll(incoming.availableTransports)
            ..add(incoming.transportType);

      _discoveredPeers[key] = existing.copyWith(
        displayName: incoming.displayName,
        transportType: incoming.transportType, // Most recent observation
        availableTransports: mergedTransports,
        rssi: incoming.rssi != 0 ? incoming.rssi : existing.rssi,
        endpointAddress: incoming.endpointAddress ?? existing.endpointAddress,
        lastSeen: incoming.lastSeen,
        isIdentityVerified: false, // Unverified at discovery
      );
    }

    _peersController.add(currentPeers);
  }

  void _startReaper() {
    _reaperTimer?.cancel();
    _reaperTimer = Timer.periodic(reaperInterval, (_) => _evictStalePeers());
  }

  void _stopReaper() {
    _reaperTimer?.cancel();
    _reaperTimer = null;
  }

  void _evictStalePeers() {
    final now = DateTime.now();
    final initialCount = _discoveredPeers.length;

    _discoveredPeers.removeWhere((id, peer) {
      final isStale = now.difference(peer.lastSeen) > staleTimeout;
      if (isStale) {
        AppLogger.debug(
          'DiscoveryCoordinator',
          'Evicted stale peer: ${peer.displayName} ($id)',
        );
      }
      return isStale;
    });

    if (_discoveredPeers.length != initialCount) {
      _peersController.add(currentPeers);
    }
  }

  void _updateStatus(DiscoveryStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
  }

  /// Manually injects a peer (primarily for unit tests and local simulations).
  void ingestPeerForTesting(DiscoveredPeer peer) {
    _handleDiscoveredPeer(peer);
  }

  /// Manually triggers stale peer eviction (primarily for unit tests).
  void evictStalePeersForTesting() {
    _evictStalePeers();
  }

  void dispose() {
    _stopReaper();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _peersController.close();
    _statusController.close();
  }
}
