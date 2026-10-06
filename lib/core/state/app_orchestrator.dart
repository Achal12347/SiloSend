import 'dart:async';

import 'package:silosend_datasharing_app/core/capabilities/capability_coordinator.dart';
import 'package:silosend_datasharing_app/core/connection/connection_manager.dart';
import 'package:silosend_datasharing_app/core/battery/battery_snapshot.dart';
import 'package:silosend_datasharing_app/core/contracts/battery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transfer_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/discovery/discovery_coordinator.dart';
import 'package:silosend_datasharing_app/core/logging/app_logger.dart';
import 'package:silosend_datasharing_app/core/security/secure_session_manager.dart';
import 'package:silosend_datasharing_app/core/transfer/file_sharing_coordinator.dart';
import 'package:silosend_datasharing_app/domain/identity/system_capabilities.dart';
import 'package:silosend_datasharing_app/domain/models/transfer_models.dart';

/// Conceptual operational lifecycle phases defined in Section 33 of
/// SiloSend Real Device Integration Plan.
enum AppOperationalPhase {
  initializing,
  ready,
  discovering,
  deviceFound,
  connecting,
  authenticating,
  connected,
  preparingTransfer,
  transferring,
  verifying,
  completed,
  tearingDown,
  disconnected,
  error;

  bool get isTransferring => this == AppOperationalPhase.transferring;
  bool get isConnected =>
      this == AppOperationalPhase.connected ||
      this == AppOperationalPhase.authenticating ||
      this == AppOperationalPhase.preparingTransfer ||
      this == AppOperationalPhase.transferring ||
      this == AppOperationalPhase.verifying ||
      this == AppOperationalPhase.completed;
}

/// Explicit domain error states required by Section 33.
/// SiloSend prohibits overloading a generic error code.
enum AppExplicitError {
  none,
  permissionRequired,
  hardwareUnavailable,
  connectionFailed,
  authenticationFailed,
  transferFailed,
  integrityFailed,
  cancelled,
  insufficientStorage;

  bool get hasError => this != AppExplicitError.none;
}

/// Unified, immutable snapshot of the centralized SiloSend application state.
class AppOrchestratorState {
  final AppOperationalPhase phase;
  final AppExplicitError explicitError;
  final String? errorMessage;
  final String? activePeerDisplayName;
  final String? activePeerId;
  final TransportType? activeTransport;
  final TransferProgress? activeTransferProgress;
  final int discoveredPeersCount;
  final bool isBatterySaverActive;
  final DateTime timestamp;

  const AppOrchestratorState({
    required this.phase,
    this.explicitError = AppExplicitError.none,
    this.errorMessage,
    this.activePeerDisplayName,
    this.activePeerId,
    this.activeTransport,
    this.activeTransferProgress,
    this.discoveredPeersCount = 0,
    this.isBatterySaverActive = false,
    required this.timestamp,
  });

  factory AppOrchestratorState.initial() => AppOrchestratorState(
    phase: AppOperationalPhase.initializing,
    timestamp: DateTime.now(),
  );

  AppOrchestratorState copyWith({
    AppOperationalPhase? phase,
    AppExplicitError? explicitError,
    String? errorMessage,
    String? activePeerDisplayName,
    String? activePeerId,
    TransportType? activeTransport,
    TransferProgress? activeTransferProgress,
    int? discoveredPeersCount,
    bool? isBatterySaverActive,
    DateTime? timestamp,
  }) {
    return AppOrchestratorState(
      phase: phase ?? this.phase,
      explicitError: explicitError ?? this.explicitError,
      errorMessage: errorMessage ?? this.errorMessage,
      activePeerDisplayName:
          activePeerDisplayName ?? this.activePeerDisplayName,
      activePeerId: activePeerId ?? this.activePeerId,
      activeTransport: activeTransport ?? this.activeTransport,
      activeTransferProgress:
          activeTransferProgress ?? this.activeTransferProgress,
      discoveredPeersCount: discoveredPeersCount ?? this.discoveredPeersCount,
      isBatterySaverActive: isBatterySaverActive ?? this.isBatterySaverActive,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}

/// Central application orchestrator (Track C: U1–U8) maintaining truthful,
/// reactive state aggregation across permissions, discovery, connection,
/// cryptography, transfer, and battery subsystems.
class AppOrchestrator {
  final CapabilityCoordinator capabilityCoordinator;
  final DiscoveryCoordinator discoveryCoordinator;
  final ConnectionManager connectionManager;
  final SecureSessionManager secureSessionManager;
  final FileSharingCoordinator fileSharingCoordinator;
  final BatteryStateProvider batteryProvider;
  final bool Function(BatterySnapshot snapshot)? isBatterySaverActiveEvaluator;

  final StreamController<AppOrchestratorState> _stateController =
      StreamController<AppOrchestratorState>.broadcast();

  AppOrchestratorState _currentState = AppOrchestratorState.initial();
  BatterySnapshot _batterySnapshot = BatterySnapshot.unknown();
  final List<StreamSubscription> _subscriptions = [];
  bool _isDisposed = false;

  AppOrchestrator({
    required this.capabilityCoordinator,
    required this.discoveryCoordinator,
    required this.connectionManager,
    required this.secureSessionManager,
    required this.fileSharingCoordinator,
    required this.batteryProvider,
    this.isBatterySaverActiveEvaluator,
  }) {
    _initListeners();
    _refreshBattery();
    _recalculateState();
  }

  AppOrchestratorState get currentState => _currentState;
  Stream<AppOrchestratorState> get stateStream => _stateController.stream;

  void _initListeners() {
    _subscriptions.add(
      capabilityCoordinator.stateStream.listen((_) => _recalculateState()),
    );
    _subscriptions.add(
      discoveryCoordinator.peersStream.listen((_) => _recalculateState()),
    );
    _subscriptions.add(
      discoveryCoordinator.statusStream.listen((_) => _recalculateState()),
    );
    _subscriptions.add(
      connectionManager.activeSessionsStream.listen((_) => _recalculateState()),
    );
    _subscriptions.add(
      secureSessionManager.secureSessions.listen((_) => _recalculateState()),
    );
    _subscriptions.add(
      fileSharingCoordinator.activeTransfersStream.listen(
        (_) => _recalculateState(),
      ),
    );
  }

  Future<void> refresh() async {
    await _refreshBattery();
    _recalculateState();
  }

  Future<void> _refreshBattery() async {
    try {
      _batterySnapshot = await batteryProvider.getBatterySnapshot();
      _recalculateState();
    } catch (_) {}
  }

  /// Evaluates all underlying subsystem states in strict priority order.
  void _recalculateState() {
    if (_isDisposed) return;

    final rawCaps = capabilityCoordinator.rawCapabilities;
    final capState = capabilityCoordinator.state;
    final peers = discoveryCoordinator.currentPeers;
    final sessions = connectionManager.activeSessions;
    final secureSessions = secureSessionManager.activeSessions;
    final transfers = fileSharingCoordinator.allTransfers;

    AppOperationalPhase phase = AppOperationalPhase.ready;
    AppExplicitError explicitError = AppExplicitError.none;
    String? errorMsg;
    String? peerName;
    String? peerId;
    TransportType? transport;
    TransferProgress? transferProgress;

    // 1. Evaluate explicit errors (Permissions & Radios)
    final isAndroid = rawCaps.platformName.toLowerCase() == 'android';
    final isNearbyPermissionRequired = isAndroid &&
        rawCaps.nearbyPermission != PermissionStatus.notRequired &&
        rawCaps.nearbyPermission != PermissionStatus.unknown;

    if (isNearbyPermissionRequired &&
        (rawCaps.nearbyPermission == PermissionStatus.denied ||
            rawCaps.nearbyPermission == PermissionStatus.permanentlyDenied)) {
      phase = AppOperationalPhase.error;
      explicitError = AppExplicitError.permissionRequired;
      errorMsg = capState.availableSummary;
    } else if (rawCaps.bluetoothState == RadioState.disabled &&
        rawCaps.lanState != NetworkState.lanAvailable) {
      phase = AppOperationalPhase.error;
      explicitError = AppExplicitError.hardwareUnavailable;
      errorMsg = 'Bluetooth is turned off and no local network is available';
    }

    // 2. Evaluate active transfers (Highest Operational Priority)
    final activeTransfer = transfers
        .where(
          (t) =>
              t.status == TransferStatus.transferring ||
              t.status == TransferStatus.verifying ||
              t.status == TransferStatus.queued ||
              t.status == TransferStatus.paused,
        )
        .firstOrNull;

    if (activeTransfer != null) {
      peerId = activeTransfer.remoteDeviceId;
      final knownPeer = fileSharingCoordinator.getKnownPeer(peerId);
      peerName = knownPeer?.displayName;

      if (activeTransfer.status == TransferStatus.verifying) {
        phase = AppOperationalPhase.verifying;
      } else if (activeTransfer.status == TransferStatus.queued) {
        phase = AppOperationalPhase.preparingTransfer;
      } else {
        phase = AppOperationalPhase.transferring;
      }
    } else {
      // Check recently finalized transfer
      final recentTransfer = transfers.firstOrNull;
      if (recentTransfer != null) {
        peerId = recentTransfer.remoteDeviceId;
        final knownPeer = fileSharingCoordinator.getKnownPeer(peerId);
        peerName = knownPeer?.displayName;

        if (recentTransfer.status == TransferStatus.completed) {
          phase = AppOperationalPhase.completed;
        } else if (recentTransfer.status == TransferStatus.cancelled) {
          phase = AppOperationalPhase.error;
          explicitError = AppExplicitError.cancelled;
          errorMsg = 'Transfer was cancelled';
        } else if (recentTransfer.status == TransferStatus.failed) {
          phase = AppOperationalPhase.error;
          explicitError = AppExplicitError.transferFailed;
          errorMsg = 'Transfer failed';
        }
      }
    }

    // 3. Evaluate Connection & Security layer if not actively transferring
    if (activeTransfer == null &&
        phase != AppOperationalPhase.completed &&
        explicitError == AppExplicitError.none) {
      final activeSession = sessions.firstOrNull;
      if (activeSession != null) {
        peerId = activeSession.remoteDeviceId;
        peerName = activeSession.info.remoteDisplayName;
        transport = activeSession.info.activeTransport;

        final isSecured = secureSessions.any(
          (s) => s.sessionId == activeSession.sessionId,
        );

        if (isSecured) {
          phase = AppOperationalPhase.connected;
        } else {
          phase = AppOperationalPhase.authenticating;
        }
      } else if (discoveryCoordinator.status == DiscoveryStatus.active) {
        // 4. Discovery layer
        if (peers.isNotEmpty) {
          phase = AppOperationalPhase.deviceFound;
        } else {
          phase = AppOperationalPhase.discovering;
        }
      } else {
        phase = AppOperationalPhase.ready;
      }
    }

    _currentState = AppOrchestratorState(
      phase: phase,
      explicitError: explicitError,
      errorMessage: errorMsg,
      activePeerDisplayName: peerName,
      activePeerId: peerId,
      activeTransport: transport,
      activeTransferProgress: transferProgress,
      discoveredPeersCount: peers.length,
      isBatterySaverActive:
          isBatterySaverActiveEvaluator != null
              ? isBatterySaverActiveEvaluator!(_batterySnapshot)
              : (_batterySnapshot.isBatterySaverActive == true),
      timestamp: DateTime.now(),
    );

    _stateController.add(_currentState);
    AppLogger.debug(
      'AppOrchestrator',
      'Orchestrator state updated: phase=${_currentState.phase}, error=${_currentState.explicitError}',
    );
  }

  /// Forces recalculation of orchestrator state.
  void refreshState() {
    _refreshBattery();
    _recalculateState();
  }

  void dispose() {
    _isDisposed = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _stateController.close();
  }
}
