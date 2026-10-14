import 'dart:async';

import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transport/transport_selection_policy.dart';
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

  SmartTransportSelectorImpl({
    required this.platformService,
    required this.batteryProvider,
    required this.connectionManager,
    required this.secureSessionManager,
    this.policy = const TransportSelectionPolicy(),
  });

  @override
  Future<TransportSelectionResult> selectTransport(
    TransportSelectionRequest request,
  ) async {
    final localCapabilities = await platformService.getCapabilities();
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

    final selectionResult = await selectTransport(effectiveRequest);

    // If an authenticated SecureSession already exists with this peer on the selected transport, reuse it
    final existingSecure = secureSessionManager.getSessionForPeer(
      peer.deviceId,
    );
    if (existingSecure != null &&
        existingSecure.state == SessionState.secured &&
        existingSecure.connectionSession.connection.type ==
            selectionResult.selectedTransport) {
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

    for (final transport in candidatesToAttempt) {
      AppLogger.info(
        'SmartTransportSelector',
        'Attempting connection to ${peer.displayName} via ${transport.name}...',
      );

      ConnectionSession? transportSession;
      try {
        transportSession = await _establishTransportConnection(
          peer: peer,
          transport: transport,
          timeout: timeout,
        );

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

        return secureSession;
      } catch (e) {
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
    throw NoViableTransportException(
      'All candidate transports failed for peer ${peer.displayName} (${peer.deviceId})',
      candidateScores: selectionResult.rankedCandidates,
      attemptErrors: attemptErrors,
    );
  }

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
        throw UnsupportedError(
          'Wi-Fi Direct transport connection is not implemented in Vayu yet',
        );
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
