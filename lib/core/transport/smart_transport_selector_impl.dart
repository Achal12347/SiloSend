import 'dart:async';

import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
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

  SmartTransportSelectorImpl({
    required this.platformService,
    required this.batteryProvider,
    required this.connectionManager,
    required this.secureSessionManager,
    this.policy = const TransportSelectionPolicy(),
    this.linkUpgrade,
    this.wifiDirectSupported,
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

  /// Route order for anything bigger than a small message (owner decision,
  /// 2026-10-19): Wi-Fi Direct handed over from Bluetooth first, even when
  /// both phones share a router (the phones then talk directly, on 5 GHz
  /// when both can, instead of every byte crossing a 2.4 GHz router twice);
  /// the shared router when Wi-Fi Direct fails; Bluetooth last.
  static int _routeRank(TransportType transport) => switch (transport) {
    TransportType.wifiDirect => 0,
    TransportType.lan => 1,
    TransportType.ble => 2,
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
        final route = _routeRank(a.transport)
            .compareTo(_routeRank(b.transport));
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

  @override
  Future<SecureSession> connectWithSmartSelection(
    DiscoveredPeer peer, {
    TransportSelectionRequest? request,
    Duration? timeout,
  }) async {
    final effectiveRequest =
        request ?? TransportSelectionRequest(targetPeer: peer);

    // An established Wi-Fi session with this phone is the best route there
    // is, even when the phone has no address of its own here (it connected
    // to us, as a Host & Client client does).
    final live = secureSessionManager.getSessionForPeer(peer.deviceId);
    if (live != null &&
        live.state == SessionState.secured &&
        live.connectionSession.connection.type == TransportType.lan) {
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
        (existingType == selectionResult.selectedTransport ||
            (selectionResult.selectedTransport == TransportType.wifiDirect &&
                existingType == TransportType.lan))) {
      AppLogger.info(
        'SmartTransportSelector',
        'Reusing existing authenticated SecureSession with ${peer.displayName} on ${selectionResult.selectedTransport.name}',
      );
      return existingSecure;
    }

    // Prioritized list of transports to attempt: primary + fallback chain
    final candidatesToAttempt = [
      selectionResult.selectedTransport,
      ...selectionResult.fallbackChain,
    ];

    final attemptErrors = <String>[];
    // A reason the peer gave is more useful to the user than "all failed".
    LinkUpgradeException? declined;

    for (final transport in candidatesToAttempt) {
      AppLogger.info(
        'SmartTransportSelector',
        'Attempting connection to ${peer.displayName} via ${transport.name}...',
      );

      ConnectionSession? transportSession;
      UpgradedLink? upgraded;
      try {
        if (transport == TransportType.wifiDirect) {
          upgraded = await _joinWifiDirect(peer, timeout);
          transportSession = await _connectInGroup(peer, upgraded, timeout);
        } else {
          transportSession = await _establishTransportConnection(
            peer: peer,
            transport: transport,
            timeout: timeout,
          );
        }

        AppLogger.info(
          'SmartTransportSelector',
          'Physical connection established with ${peer.displayName} on ${transport.name}. Elevating to SecureSession...',
        );

        // Elevate transport connection to authenticated SecureSession
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
        return secureSession;
      } catch (e) {
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
    while (true) {
      try {
        return await connectionManager.connectToLanPeer(
          remoteAddress: link.host,
          remotePort: link.port,
          targetDeviceId: peer.deviceId,
          timeout: timeout ?? const Duration(seconds: 5),
        );
      } on Exception catch (e) {
        if (DateTime.now().isAfter(until)) rethrow;
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
