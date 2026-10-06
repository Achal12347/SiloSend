import 'dart:async';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';

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

  final Set<TransportType> _activeTransports = {};
  final _operationalStateController =
      StreamController<DiscoveryOperationalState>.broadcast();

  Timer? _reaperTimer;
  DiscoveryStatus _status = DiscoveryStatus.idle;
  DateTime? _discoveryStartedAt;
  Timer? _initialSearchTimer;

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

  /// Physical transports currently active and scanning.
  Set<TransportType> get activeTransports =>
      Set.unmodifiable(_activeTransports);

  bool _isBatterySaverActive = false;

  /// Whether battery saver throttling is currently active.
  bool get isBatterySaverActive => _isBatterySaverActive;

  /// Sets battery saver throttling mode across all discovery services.
  void setBatterySaver(bool enabled) {
    if (_isBatterySaverActive == enabled) return;
    _isBatterySaverActive = enabled;
    for (final service in services) {
      if (service.transportType == TransportType.ble) {
        try {
          (service as dynamic).setBatterySaver(enabled);
        } catch (_) {}
      }
    }
    if (_status == DiscoveryStatus.active) {
      _startReaper();
    }
  }

  /// Current high-level operational state for product UX.
  DiscoveryOperationalState get operationalState {
    if (_status == DiscoveryStatus.idle) {
      return DiscoveryOperationalState.idle;
    }
    if (_status == DiscoveryStatus.error ||
        (_status == DiscoveryStatus.active && _activeTransports.isEmpty)) {
      return DiscoveryOperationalState.actionRequired;
    }
    if (_discoveredPeers.isNotEmpty) {
      return DiscoveryOperationalState.ready;
    }
    if (_discoveryStartedAt != null &&
        DateTime.now().difference(_discoveryStartedAt!) >=
            const Duration(seconds: 4)) {
      return DiscoveryOperationalState.noDevices;
    }
    return DiscoveryOperationalState.searching;
  }

  /// Reactive stream of operational state transitions.
  Stream<DiscoveryOperationalState> get operationalStateStream =>
      _operationalStateController.stream;

  /// Starts discovery scanning across all configured transport services.
  Future<void> startDiscovery() async {
    if (_status == DiscoveryStatus.active) return;

    _updateStatus(DiscoveryStatus.starting);
    AppLogger.info(
      'DiscoveryCoordinator',
      'Starting multi-transport discovery...',
    );

    var startedCount = 0;
    Object? lastError;
    _activeTransports.clear();
    for (final service in services) {
      try {
        await service.startDiscovery();
        startedCount++;
        _activeTransports.add(service.transportType);
      } catch (e, stack) {
        lastError = e;
        AppLogger.warning(
          'DiscoveryCoordinator',
          'Failed to start discovery service ${service.transportType}: $e',
          stackTrace: stack,
        );
      }
    }

    if (startedCount == 0) {
      _updateStatus(DiscoveryStatus.error);
      AppLogger.error(
        'DiscoveryCoordinator',
        'No discovery services could be started',
      );
      if (lastError is Exception) {
        throw lastError;
      }
      throw Exception(
        lastError?.toString() ?? 'No discovery services could be started',
      );
    }

    _startReaper();
    _discoveryStartedAt = DateTime.now();
    _initialSearchTimer?.cancel();
    _initialSearchTimer = Timer(const Duration(seconds: 4), () {
      if (!_operationalStateController.isClosed) {
        _operationalStateController.add(operationalState);
      }
    });
    _updateStatus(DiscoveryStatus.active);
    AppLogger.info(
      'DiscoveryCoordinator',
      'Multi-transport discovery active ($startedCount/${services.length} services started)',
    );
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
    _initialSearchTimer?.cancel();
    _initialSearchTimer = null;
    _discoveryStartedAt = null;
    await Future.wait(
      services.map((s) => s.stopDiscovery().catchError((_) {})),
    );
    _activeTransports.clear();
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
    for (final service in services) {
      try {
        await service.startAdvertising(advertisement);
      } catch (e) {
        AppLogger.warning(
          'DiscoveryCoordinator',
          'Failed to start advertising on ${service.transportType}: $e',
        );
      }
    }
  }

  /// Stops advertising local presence across all transports.
  Future<void> stopAdvertising() async {
    AppLogger.info(
      'DiscoveryCoordinator',
      'Stopping multi-transport advertising...',
    );
    await Future.wait(
      services.map((s) => s.stopAdvertising().catchError((_) {})),
    );
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

      final mergedEndpoints = Map<TransportType, String>.from(
        existing.transportEndpoints,
      )..addAll(incoming.transportEndpoints);

      _discoveredPeers[key] = existing.copyWith(
        displayName: incoming.displayName,
        transportType: incoming.transportType, // Most recent observation
        availableTransports: mergedTransports,
        transportEndpoints: mergedEndpoints,
        rssi: incoming.rssi != 0 ? incoming.rssi : existing.rssi,
        lastSeen: incoming.lastSeen,
        isIdentityVerified: false, // Unverified at discovery
      );
    }

    _peersController.add(currentPeers);
    if (!_operationalStateController.isClosed) {
      _operationalStateController.add(operationalState);
    }
  }

  void _startReaper() {
    _reaperTimer?.cancel();
    final interval = _isBatterySaverActive
        ? Duration(seconds: reaperInterval.inSeconds * 2)
        : reaperInterval;
    _reaperTimer = Timer.periodic(interval, (_) => _evictStalePeers());
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
      if (!_operationalStateController.isClosed) {
        _operationalStateController.add(operationalState);
      }
    }
  }

  void _updateStatus(DiscoveryStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
    if (!_operationalStateController.isClosed) {
      _operationalStateController.add(operationalState);
    }
  }

  /// Manually injects a peer (primarily for unit tests and local simulations).
  void ingestPeerForTesting(DiscoveredPeer peer) {
    _activeTransports.add(peer.transportType);
    _handleDiscoveredPeer(peer);
  }

  /// Manually triggers stale peer eviction (primarily for unit tests).
  void evictStalePeersForTesting() {
    _evictStalePeers();
  }

  /// Sets discovery start time directly for test timing simulations.
  void setDiscoveryStartedAtForTesting(DateTime? time) {
    _discoveryStartedAt = time;
    if (!_operationalStateController.isClosed) {
      _operationalStateController.add(operationalState);
    }
  }

  void dispose() {
    _stopReaper();
    _initialSearchTimer?.cancel();
    _initialSearchTimer = null;
    for (final service in services) {
      service.stopAdvertising().ignore();
      service.stopDiscovery().ignore();
    }
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _peersController.close();
    _statusController.close();
    _operationalStateController.close();
  }
}
