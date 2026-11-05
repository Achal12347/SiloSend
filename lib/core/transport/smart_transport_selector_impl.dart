import 'dart:async';

import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/contracts/connection_attempt_progress.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/connection/link_upgrade_service.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transport/transport_selection_policy.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';

/// Intelligent, hardware-aware, and headless transport selection engine.
///
/// Automatically evaluates available transports, ranks candidate media according
/// to multi-criteria heuristics, and coordinates safe connection establishment
/// and automated fallback failover.
class SmartTransportSelectorImpl implements TransportSelector {
  final PlatformService platformService;
  final BatteryStateProvider batteryProvider;
  final ConnectionManager connectionManager;
  final SecureSessionManager secureSessionManager;
  final TransportSelectionPolicy policy;

  /// Moves a Bluetooth session onto Wi-Fi Direct; null where unavailable.
  final LinkUpgradeService? linkUpgrade;

  /// Whether this phone has Wi-Fi Direct (the platform capability probe
  /// does not report it).
  final Future<bool> Function()? wifiDirectSupported;
  final double? Function(String peerId, TransportType transport)?
  observedThroughput;
  final void Function(ConnectionAttemptProgress progress)? onConnectionProgress;

  /// Testing switch in Diagnostics: skip the shared Wi-Fi, so Wi-Fi Direct can
  /// be tried between phones that are on the same network.
  final bool Function()? avoidSharedWifi;

  SmartTransportSelectorImpl({
    required this.platformService,
    required this.batteryProvider,
    required this.connectionManager,
    required this.secureSessionManager,
    this.policy = const TransportSelectionPolicy(),
    this.linkUpgrade,
    this.wifiDirectSupported,
    this.observedThroughput,
    this.onConnectionProgress,
    this.avoidSharedWifi,
  });

  Future<DeviceCapabilities> _localCapabilities() async {
    final capabilities = await platformService.getCapabilities();
    final probe = wifiDirectSupported;
    if (probe == null || linkUpgrade == null) {
      return capabilities.copyWith(wifiDirect: CapabilityStatus.unsupported);
    }
    return capabilities.copyWith(
      wifiDirect: await probe()
          ? CapabilityStatus.supported
          : CapabilityStatus.unsupported,
    );
  }

  /// Prefer an already-discovered LAN route. Wi-Fi Direct is the high-speed
  /// fallback when there is no usable shared-network endpoint.
  static int _routeRank(TransportType transport) => switch (transport) {
    TransportType.lan => 0,
    TransportType.wifiDirect => 1,
    TransportType.ble => 2,
    TransportType.relay => 3,
  };

  @override
  Future<TransportSelectionResult> selectTransport(
    TransportSelectionRequest request,
  ) async {
    final localCapabilities = await _localCapabilities();
    final batterySnapshot = await batteryProvider.getBatterySnapshot();

    // Check if an active connection session already exists with the target peer
    final existingSession = connectionManager.getSessionByDeviceId(
      request.targetPeer.deviceId,
    );
    final existingTransport = existingSession?.isActive == true
        ? existingSession?.connection.type
        : null;

    final evaluatedScores = <TransportCandidateScore>[];

    // Evaluate all known TransportTypes
    for (final transport in TransportType.values) {
      final hasSession = existingTransport == transport;
      final score = policy.evaluateCandidate(
        transport: transport,
        request: request,
        localCapabilities: localCapabilities,
        batterySnapshot: batterySnapshot,
        hasExistingActiveSession: hasSession,
        existingLinkMetrics: hasSession
            ? existingSession?.currentMetrics
            : null,
      );
      evaluatedScores.add(score);
    }

    // Sort all evaluated candidates: available candidates first (sorted by score descending), then disqualified candidates
    evaluatedScores.sort((a, b) {
      if (a.isAvailable && !b.isAvailable) return -1;
      if (!a.isAvailable && b.isAvailable) return 1;
      if (request.payloadSizeBytes > policy.bleOptimalPayloadBytes) {
        final route = _compareLargePayloadRoutes(
          a.transport,
          b.transport,
          request,
        );
        if (route != 0) return route;
      }
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;

      // Deterministic tie-breaker when scores are identical:
      // If payload > 32 KiB, prefer LAN over BLE
      if (request.payloadSizeBytes > policy.bleOptimalPayloadBytes) {
        if (a.transport == TransportType.lan) return -1;
        if (b.transport == TransportType.lan) return 1;
      } else {
        // If small payload, prefer BLE over LAN
        if (a.transport == TransportType.ble) return -1;
        if (b.transport == TransportType.ble) return 1;
      }
      return a.transport.index.compareTo(b.transport.index);
    });

    // Filter viable/available transports
    final available = evaluatedScores.where((c) => c.isAvailable).toList();

    if (available.isEmpty) {
      throw NoViableTransportException(
        'No available or viable transport for peer ${request.targetPeer.displayName} (${request.targetPeer.deviceId})',
        candidateScores: evaluatedScores,
      );
    }

    final selected = available.first.transport;
    final fallbackChain = available.skip(1).map((c) => c.transport).toList();

    // Construct a sanitized rationale explanation
    final rationale = _generateRationale(
      selected: available.first,
      request: request,
      fallbacks: fallbackChain,
      batterySnapshot: batterySnapshot,
    );

    AppLogger.info(
      'SmartTransportSelector',
      'Selected ${selected.name} for ${request.targetPeer.displayName} (bytes: ${request.payloadSizeBytes}): $rationale',
    );

    return TransportSelectionResult(
      selectedTransport: selected,
      rankedCandidates: evaluatedScores,
      fallbackChain: fallbackChain,
      rationale: rationale,
    );
  }

  int _compareLargePayloadRoutes(
    TransportType a,
    TransportType b,
    TransportSelectionRequest request,
  ) {
    if ((a == TransportType.lan && b == TransportType.wifiDirect) ||
        (a == TransportType.wifiDirect && b == TransportType.lan)) {
      final lanRate = observedThroughput?.call(
        request.targetPeer.deviceId,
        TransportType.lan,
      );
      final directRate = observedThroughput?.call(
        request.targetPeer.deviceId,
        TransportType.wifiDirect,
      );
      // Do not switch on one incomplete sample. Until both routes have
      // measurements, LAN avoids Wi-Fi Direct group-setup latency.
      if (lanRate != null &&
          directRate != null &&
          lanRate > 0 &&
          directRate > 0) {
        const setupCostSeconds = 8.0;
        final bytes = request.payloadSizeBytes.toDouble();
        final lanSeconds = bytes / lanRate;
        final directSeconds = setupCostSeconds + bytes / directRate;
        final result = lanSeconds.compareTo(directSeconds);
        if (result != 0) return a == TransportType.lan ? result : -result;
      }
    }
    return _routeRank(a).compareTo(_routeRank(b));
  }

  /// Reaches a phone through other phones when no direct route works
  /// (Phase 12 mesh); null where there is no mesh.
  Future<SecureSession> Function(DiscoveredPeer peer)? meshFallback;

  /// Every direct route first; the mesh only when all of them failed (or
  /// there is none). The direct failure is reported when the mesh has no
  /// route either, unless there was no direct route to try at all.
  @override
  Future<SecureSession> connectWithSmartSelection(
    DiscoveredPeer peer, {
    TransportSelectionRequest? request,
    Duration? timeout,
  }) async {
    onConnectionProgress?.call(
      ConnectionAttemptProgress(
        peerId: peer.deviceId,
        peerName: peer.displayName,
        stage: ConnectionAttemptStage.evaluating,
      ),
    );
    try {
      return await connectDirectOnly(peer, request: request, timeout: timeout);
    } catch (direct) {
      final mesh = meshFallback;
      if (mesh == null ||
          direct is LinkUpgradeException && direct.declined != null) {
        onConnectionProgress?.call(
          ConnectionAttemptProgress(
            peerId: peer.deviceId,
            peerName: peer.displayName,
            stage: ConnectionAttemptStage.failed,
          ),
        );
        rethrow;
      }
      AppLogger.info(
        'SmartTransportSelector',
        'No direct route to ${peer.displayName}; trying through nearby phones',
      );
      try {
        final relayed = await mesh(peer);
        onConnectionProgress?.call(
          ConnectionAttemptProgress(
            peerId: peer.deviceId,
            peerName: peer.displayName,
            stage: ConnectionAttemptStage.connected,
            transport: TransportType.relay,
          ),
        );
        return relayed;
      } catch (meshError) {
        onConnectionProgress?.call(
          ConnectionAttemptProgress(
            peerId: peer.deviceId,
            peerName: peer.displayName,
            stage: ConnectionAttemptStage.failed,
          ),
        );
        final noDirectRoute =
            direct is NoViableTransportException &&
            direct.attemptErrors.isEmpty;
        if (noDirectRoute) rethrow;
        throw direct;
      }
    }
  }

  /// Direct routes only (shared Wi-Fi, Wi-Fi Direct, Bluetooth). The mesh
  /// itself uses this to reach its neighbours.
  Future<SecureSession> connectDirectOnly(
    DiscoveredPeer peer, {
    TransportSelectionRequest? request,
    Duration? timeout,
  }) async {
    final effectiveRequest =
        request ?? TransportSelectionRequest(targetPeer: peer);
    void report(ConnectionAttemptStage stage, {TransportType? transport}) {
      onConnectionProgress?.call(
        ConnectionAttemptProgress(
          peerId: peer.deviceId,
          peerName: peer.displayName,
          stage: stage,
          transport: transport,
        ),
      );
    }

    report(ConnectionAttemptStage.evaluating);

    final avoidLan = avoidSharedWifi?.call() ?? false;
    bool onSharedWifi(SecureSessionImpl s) =>
        s.connectionSession.info.routeName == 'lan';

    // An established Wi-Fi session with this phone is the best route there
    // is, even when the phone has no address of its own here (it connected
    // to us, as a Host & Client client does).
    final live = secureSessionManager.getSessionForPeer(peer.deviceId);
    if (live != null &&
        live.state == SessionState.secured &&
        live.connectionSession.connection.type == TransportType.lan &&
        !(avoidLan && onSharedWifi(live))) {
      report(ConnectionAttemptStage.connected, transport: TransportType.lan);
      return live;
    }

    final selectionResult = await selectTransport(effectiveRequest);

    // If an authenticated SecureSession already exists with this peer on the selected transport, reuse it
    final existingSecure = secureSessionManager.getSessionForPeer(
      peer.deviceId,
    );
    final existingType = existingSecure?.connectionSession.connection.type;
    // A Wi-Fi Direct link is TCP like the shared network: one already up
    // with this peer is reused.
    if (existingSecure != null &&
        existingSecure.state == SessionState.secured &&
        !(avoidLan && onSharedWifi(existingSecure)) &&
        (existingType == selectionResult.selectedTransport ||
            (selectionResult.selectedTransport == TransportType.wifiDirect &&
                existingType == TransportType.lan))) {
      AppLogger.info(
        'SmartTransportSelector',
        'Reusing existing authenticated SecureSession with ${peer.displayName} on ${selectionResult.selectedTransport.name}',
      );
      report(
        ConnectionAttemptStage.connected,
        transport: selectionResult.selectedTransport,
      );
      return existingSecure;
    }

    // Prioritized list of transports to attempt: primary + fallback chain
    // An address inside a Wi-Fi Direct group is not the shared Wi-Fi.
    final lanAddress = peer.lanEndpoint ?? peer.endpointAddress;
    final skipLan =
        avoidLan && !(lanAddress?.startsWith('192.168.49.') ?? false);
    final candidatesToAttempt = [
      selectionResult.selectedTransport,
      ...selectionResult.fallbackChain,
    ].where((t) => !(skipLan && t == TransportType.lan)).toList();

    final attemptErrors = <String>[];
    // A reason the peer gave is more useful to the user than "all failed".
    LinkUpgradeException? declined;

    for (final transport in candidatesToAttempt) {
      report(
        attemptErrors.isEmpty
            ? ConnectionAttemptStage.connecting
            : ConnectionAttemptStage.fallback,
        transport: transport,
      );
      AppLogger.info(
        'SmartTransportSelector',
        'Attempting connection to ${peer.displayName} via ${transport.name}...',
      );

      ConnectionSession? transportSession;
      UpgradedLink? upgraded;
      var stage = 'physical_connect';
      try {
        if (transport == TransportType.wifiDirect) {
          stage = 'ble_handoff';
          report(ConnectionAttemptStage.handingOff, transport: transport);
          upgraded = await _joinWifiDirect(peer, timeout);
          stage = 'wifi_direct_tcp_connect';
          report(ConnectionAttemptStage.joining, transport: transport);
          transportSession = await _connectInGroup(peer, upgraded, timeout);
        } else {
          transportSession = await _establishTransportConnection(
            peer: peer,
            transport: transport,
            timeout: timeout,
            sourceAddress: effectiveRequest.localSourceAddress,
          );
        }

        AppLogger.info(
          'SmartTransportSelector',
          'Physical connection established with ${peer.displayName} on ${transport.name}. Elevating to SecureSession...',
        );

        // Elevate transport connection to authenticated SecureSession
        stage = 'secure_handshake';
        report(ConnectionAttemptStage.securing, transport: transport);
        AppLogger.info(
          'TransportDiagnostic',
          'stage=secure_handshake_started transport=${transport.name}',
        );
        final secureSession = await secureSessionManager
            .secureOutboundConnection(
              transportSession,
              timeout: timeout ?? const Duration(seconds: 10),
            );

        AppLogger.info(
          'SmartTransportSelector',
          'Successfully established and verified SecureSession with ${peer.displayName} on ${transport.name}',
        );

        if (upgraded != null) {
          linkUpgrade!.leaveWhenClosed(transportSession, upgraded);
        }
        report(ConnectionAttemptStage.connected, transport: transport);
        return secureSession;
      } catch (e) {
        AppLogger.warning(
          'TransportDiagnostic',
          'stage=$stage result=failed errorType=${e.runtimeType}',
        );
        if (e is LinkUpgradeException && e.declined != null) declined = e;
        if (upgraded != null) {
          try {
            await upgraded.leave();
          } catch (_) {}
        }
        final errorMsg = '${transport.name} failed: $e';
        attemptErrors.add(errorMsg);
        AppLogger.warning(
          'SmartTransportSelector',
          'Connection or security handshake failed on ${transport.name} for ${peer.displayName}: $e. Attempting fallback if available...',
        );

        // Clean up failed physical session if partially opened
        if (transportSession != null && transportSession.isActive) {
          try {
            await transportSession.close(reason: 'fallback_failover');
          } catch (_) {}
        }
      }
    }

    // All primary and fallback attempts exhausted
    if (declined != null) throw declined;
    report(ConnectionAttemptStage.failed);
    throw NoViableTransportException(
      'All candidate transports failed for peer ${peer.displayName} (${peer.deviceId})',
      candidateScores: selectionResult.rankedCandidates,
      attemptErrors: attemptErrors,
    );
  }

  /// Connects to the peer's server inside a group just joined. The first
  /// tries can fail while the group's routes settle, so it tries again for a
  /// few seconds before giving up on the group.
  Future<ConnectionSession> _connectInGroup(
    DiscoveredPeer peer,
    UpgradedLink link,
    Duration? timeout,
  ) async {
    final until = DateTime.now().add(groupConnectWindow);
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        AppLogger.info(
          'TransportDiagnostic',
          'stage=wifi_direct_tcp_connect_started attempt=$attempt '
              'host=${link.host} port=${link.port} '
              'localAddressPresent=${link.localAddress != null}',
        );
        final connection = await connectionManager.connectToLanPeer(
          remoteAddress: link.host,
          remotePort: link.port,
          targetDeviceId: peer.deviceId,
          timeout: timeout ?? const Duration(seconds: 5),
          sourceAddress: link.localAddress,
        );
        AppLogger.info(
          'TransportDiagnostic',
          'stage=wifi_direct_tcp_connected attempt=$attempt remote=${link.host}:${link.port}',
        );
        return connection;
      } on Exception catch (e) {
        if (DateTime.now().isAfter(until)) {
          AppLogger.error(
            'TransportDiagnostic',
            'stage=wifi_direct_tcp_connect_failed attempts=$attempt '
                'errorType=${e.runtimeType} host=${link.host} port=${link.port}',
          );
          rethrow;
        }
        AppLogger.info(
          'SmartTransportSelector',
          'Group joined but ${link.host} not reachable yet ($e); retrying',
        );
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  /// How long to keep trying the peer's server after joining its group.
  static const Duration groupConnectWindow = Duration(seconds: 8);

  /// Hands Wi-Fi Direct credentials over the encrypted Bluetooth session
  /// (opened here if needed) and joins the group the peer created. A
  /// Bluetooth session opened only for this is closed with the group, so
  /// nothing stays connected once the transfer is over.
  Future<UpgradedLink> _joinWifiDirect(
    DiscoveredPeer peer,
    Duration? timeout,
  ) async {
    final upgrader = linkUpgrade;
    if (upgrader == null) {
      throw UnsupportedError('Wi-Fi Direct is not available on this phone');
    }
    var control = secureSessionManager.getSessionForPeer(peer.deviceId);
    var openedHere = false;
    if (control == null || !control.isEstablished) {
      openedHere = true;
      final bluetooth = await _establishTransportConnection(
        peer: peer,
        transport: TransportType.ble,
        timeout: timeout,
      );
      control = await secureSessionManager.secureOutboundConnection(
        bluetooth,
        timeout: timeout ?? const Duration(seconds: 15),
      );
    }
    if (!_supportsUpgrade(control)) {
      throw const LinkUpgradeException(
        'The other phone runs an older Vayu without Wi-Fi Direct',
      );
    }
    AppLogger.info(
      'SmartTransportSelector',
      'Asking ${peer.displayName} for Wi-Fi Direct over '
          '${control.connectionSession.connection.type.name}',
    );
    final SecureSessionImpl bluetoothControl = control;
    final UpgradedLink link;
    try {
      link = await upgrader.upgrade(control);
    } catch (_) {
      if (openedHere) await _closeQuietly(bluetoothControl, 'upgrade_failed');
      rethrow;
    }
    if (!openedHere) return link;
    return UpgradedLink(
      host: link.host,
      port: link.port,
      frequencyMhz: link.frequencyMhz,
      leave: () async {
        await link.leave();
        await _closeQuietly(bluetoothControl, 'wifi_direct_finished');
      },
    );
  }

  static Future<void> _closeQuietly(SecureSessionImpl s, String reason) async {
    try {
      await s.connectionSession.close(reason: reason);
    } catch (_) {}
  }

  static bool _supportsUpgrade(SecureSessionImpl session) => session
      .connectionSession
      .info
      .remoteFeatures
      .contains(AppConstants.featureLinkUpgrade);

  /// Establishes the physical transport-layer connection for the specified transport type.
  Future<ConnectionSession> _establishTransportConnection({
    required DiscoveredPeer peer,
    required TransportType transport,
    Duration? timeout,
    String? sourceAddress,
  }) async {
    switch (transport) {
      case TransportType.lan:
        final endpoint = peer.lanEndpoint ?? peer.endpointAddress;
        if (endpoint == null || !endpoint.contains(':')) {
          throw ArgumentError(
            'Missing or invalid LAN endpoint for ${peer.displayName}: $endpoint',
          );
        }
        final colonIndex = endpoint.lastIndexOf(':');
        final host = endpoint.substring(0, colonIndex);
        final port = int.tryParse(endpoint.substring(colonIndex + 1)) ?? 53531;

        return connectionManager.connectToLanPeer(
          remoteAddress: host,
          remotePort: port,
          targetDeviceId: peer.deviceId,
          timeout: timeout,
          sourceAddress: sourceAddress,
        );

      case TransportType.ble:
        final address = peer.bleEndpoint ?? peer.endpointAddress;
        if (address == null || address.isEmpty) {
          throw ArgumentError(
            'Missing BLE address endpoint for ${peer.displayName}',
          );
        }

        return connectionManager.connectToBlePeer(
          remoteAddress: address,
          targetDeviceId: peer.deviceId,
          timeout: timeout,
        );

      case TransportType.wifiDirect:
        // Joined through [_joinWifiDirect]; never a direct physical link.
        throw UnsupportedError('Wi-Fi Direct is joined over Bluetooth first');
      case TransportType.relay:
        // Opened by the mesh only, after every direct route failed.
        throw UnsupportedError('Relayed sessions are opened by the mesh');
    }
  }

  String _generateRationale({
    required TransportCandidateScore selected,
    required TransportSelectionRequest request,
    required List<TransportType> fallbacks,
    required BatterySnapshot batterySnapshot,
  }) {
    final buffer = StringBuffer();
    buffer.write(
      'Selected ${selected.transport.name} (score: ${selected.score.toStringAsFixed(1)}). ',
    );

    if (selected.transport == TransportType.lan) {
      if (request.payloadSizeBytes > policy.bleMediumPayloadBytes) {
        buffer.write(
          'High-throughput path preferred for large transfer (${request.payloadSizeBytes} bytes). ',
        );
      } else {
        buffer.write(
          'LAN preferred due to zero radio pairing setup and active subnet connectivity. ',
        );
      }
    } else if (selected.transport == TransportType.ble) {
      buffer.write(
        'BLE preferred for small payload (${request.payloadSizeBytes} bytes) with minimal radio power. ',
      );
    }

    if (batterySnapshot.isLowBattery ||
        batterySnapshot.isBatterySaverActive == true) {
      buffer.write(
        'Power-conscious scoring active (level: ${batterySnapshot.batteryLevel}%, saver: ${batterySnapshot.isBatterySaverActive}). ',
      );
    }

    if (fallbacks.isNotEmpty) {
      buffer.write('Fallbacks: [${fallbacks.map((t) => t.name).join(', ')}].');
    } else {
      buffer.write('No fallback transports available.');
    }

    return buffer.toString();
  }
}
