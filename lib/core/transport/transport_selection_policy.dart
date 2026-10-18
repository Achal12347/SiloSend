import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';

/// Configurable decision policy and multi-criteria scoring algorithm for Smart Transport Selection.
class TransportSelectionPolicy {
  /// Maximum transfer size (in bytes) where BLE is considered optimal (e.g. messages, contacts).
  final int bleOptimalPayloadBytes;

  /// Transfer size (in bytes) beyond which BLE efficiency drops significantly.
  final int bleMediumPayloadBytes;

  /// Maximum recommended transfer size for BLE (256 KiB).
  ///
  /// NOTE: This is a transport-suitability policy ceiling (to prevent multi-hour transfers
  /// over BLE's ~5-20 KB/s bandwidth), NOT a physical transfer engine chunk limit.
  final int bleMaxRecommendedPayloadBytes;

  /// Battery percentage threshold below which low-power mode applies (default 30%).
  final int lowBatteryThreshold;

  /// Battery percentage threshold below which critical power saving applies (default 15%).
  final int criticalBatteryThreshold;

  /// Weights for scoring components (sum to 100.0)
  final double weightPayload;
  final double weightLanPreference;
  final double weightBattery;
  final double weightExistingSession;
  final double weightSignalQuality;

  const TransportSelectionPolicy({
    this.bleOptimalPayloadBytes = 32 * 1024, // 32 KiB
    this.bleMediumPayloadBytes = 128 * 1024, // 128 KiB
    this.bleMaxRecommendedPayloadBytes = 256 * 1024, // 256 KiB
    this.lowBatteryThreshold = 30,
    this.criticalBatteryThreshold = 15,
    this.weightPayload = 35.0,
    this.weightLanPreference = 25.0,
    this.weightBattery = 20.0,
    this.weightExistingSession = 15.0,
    this.weightSignalQuality = 5.0,
  });

  /// Evaluates a single candidate transport against the selection criteria.
  ///
  /// Strictly performs HARD DISQUALIFICATION before scoring:
  /// Disqualified transports receive score 0.0 and isAvailable = false.
  TransportCandidateScore evaluateCandidate({
    required TransportType transport,
    required TransportSelectionRequest request,
    required DeviceCapabilities localCapabilities,
    required BatterySnapshot batterySnapshot,
    required bool hasExistingActiveSession,
    LinkMetrics? existingLinkMetrics,
  }) {
    // -------------------------------------------------------------
    // STEP 1: Hard Disqualification Pre-Check
    // -------------------------------------------------------------
    final disqualification = checkDisqualification(
      transport: transport,
      request: request,
      localCapabilities: localCapabilities,
    );

    if (disqualification != null) {
      return TransportCandidateScore(
        transport: transport,
        score: 0.0,
        isAvailable: false,
        disqualifyReason: disqualification,
        factors: const {},
      );
    }

    // -------------------------------------------------------------
    // STEP 2: Multi-Criteria Scoring (0.0 to 100.0)
    // -------------------------------------------------------------
    final factors = <String, double>{};

    // 2.1 Payload Suitability Score (0 to weightPayload)
    final payloadScore = scorePayloadSuitability(
      transport,
      request.payloadSizeBytes,
    );
    factors['payloadSuitability'] = payloadScore;

    // 2.2 LAN Preference Score (0 to weightLanPreference)
    final lanScore = scoreLanPreference(transport, request.targetPeer);
    factors['lanPreference'] = lanScore;

    // 2.3 Battery Conservation Score (0 to weightBattery)
    final batteryScore = scoreBattery(
      transport: transport,
      snapshot: batterySnapshot,
      batteryAware: request.batteryAware,
    );
    factors['batteryConservation'] = batteryScore;

    // 2.4 Existing Active Session Bonus (0 to weightExistingSession)
    final sessionScore = hasExistingActiveSession ? weightExistingSession : 0.0;
    factors['existingSession'] = sessionScore;

    // 2.5 Signal Quality / Link Metrics Score (0 to weightSignalQuality)
    final signalScore = scoreSignalQuality(
      transport: transport,
      peer: request.targetPeer,
      metrics: existingLinkMetrics,
    );
    factors['signalQuality'] = signalScore;

    // Composite total (clamped to 0.0 .. 100.0)
    final totalScore =
        (payloadScore + lanScore + batteryScore + sessionScore + signalScore)
            .clamp(0.0, 100.0);

    return TransportCandidateScore(
      transport: transport,
      score: totalScore,
      isAvailable: true,
      factors: factors,
    );
  }

  /// Determines whether a transport is disqualified prior to scoring.
  String? checkDisqualification({
    required TransportType transport,
    required TransportSelectionRequest request,
    required DeviceCapabilities localCapabilities,
  }) {
    if (transport == TransportType.wifiDirect) {
      return _wifiDirectDisqualification(request, localCapabilities);
    }

    // Check local hardware capability
    if (transport == TransportType.ble && !localCapabilities.supportsBle) {
      return 'local_hardware_unsupported';
    }

    // Check remote peer advertised support
    if (!request.targetPeer.availableTransports.contains(transport)) {
      return 'peer_missing_transport';
    }

    // Check transport-specific prerequisites
    if (transport == TransportType.lan) {
      final endpoint = request.targetPeer.endpointAddress;
      if (endpoint == null || !endpoint.contains(':')) {
        return 'missing_valid_lan_endpoint';
      }
    }

    if (transport == TransportType.ble) {
      // Disqualify if transfer size exceeds BLE maximum recommended transfer size
      if (request.payloadSizeBytes > bleMaxRecommendedPayloadBytes) {
        return 'payload_exceeds_ble_max_recommended';
      }
    }

    return null;
  }

  /// Wi-Fi Direct is used when the peer cannot be reached on a shared
  /// network: found over Bluetooth, which carries the group's credentials
  /// inside the encrypted session. Small items stay on Bluetooth (making a
  /// group takes seconds).
  String? _wifiDirectDisqualification(
    TransportSelectionRequest request,
    DeviceCapabilities localCapabilities,
  ) {
    final peer = request.targetPeer;
    if (!localCapabilities.supportsWifiDirect) {
      return 'local_hardware_unsupported';
    }
    if (!peer.availableTransports.contains(TransportType.wifiDirect)) {
      return 'peer_missing_transport';
    }
    final bleEndpoint = peer.bleEndpoint;
    if (!peer.availableTransports.contains(TransportType.ble) ||
        bleEndpoint == null ||
        bleEndpoint.isEmpty) {
      return 'no_bluetooth_to_hand_over';
    }
    if (request.payloadSizeBytes <= bleOptimalPayloadBytes) {
      return 'payload_small_use_ble';
    }
    return null;
  }

  /// Scores payload suitability for the candidate transport.
  double scorePayloadSuitability(
    TransportType transport,
    int payloadSizeBytes,
  ) {
    if (transport == TransportType.ble) {
      if (payloadSizeBytes <= bleOptimalPayloadBytes) {
        return weightPayload; // 35.0 (Optimal for messages, contacts, tiny payloads)
      } else if (payloadSizeBytes <= bleMediumPayloadBytes) {
        return weightPayload * 0.43; // ~15.0 pts (Usable)
      } else {
        return 0.0; // 0.0 pts (Impractically slow, LAN preferred)
      }
    }

    if (transport == TransportType.lan ||
        transport == TransportType.wifiDirect) {
      if (payloadSizeBytes > bleMediumPayloadBytes) {
        return weightPayload; // 35.0 (Optimal for files, streams, large payloads)
      } else if (payloadSizeBytes > bleOptimalPayloadBytes) {
        return weightPayload * 0.86; // ~30.0 pts (High throughput)
      } else {
        return weightPayload *
            0.57; // ~20.0 pts (Usable, but higher setup than BLE)
      }
    }

    return 0.0;
  }

  /// Scores LAN preference when valid endpoint and connectivity are verified.
  double scoreLanPreference(TransportType transport, DiscoveredPeer peer) {
    if (transport != TransportType.lan) return 0.0;

    final endpoint = peer.endpointAddress;
    if (endpoint != null &&
        endpoint.contains(':') &&
        peer.availableTransports.contains(TransportType.lan)) {
      return weightLanPreference; // 25.0
    }
    return 0.0;
  }

  /// Scores battery conservation.
  ///
  /// Strictly adheres to the No Mock Data rule:
  /// When battery state is unknown, returns neutral score (10.0) without fabricating values.
  double scoreBattery({
    required TransportType transport,
    required BatterySnapshot snapshot,
    required bool batteryAware,
  }) {
    if (!batteryAware) {
      return weightBattery; // 20.0
    }

    // Explicit Unknown Battery Policy (No Mock Data)
    if (snapshot.isUnknown) {
      return weightBattery * 0.5; // 10.0 (Neutral baseline)
    }

    // Device is charging or has plenty of battery
    if (snapshot.isCharging == true ||
        (snapshot.batteryLevel != null &&
            snapshot.batteryLevel! > lowBatteryThreshold &&
            snapshot.isBatterySaverActive != true)) {
      return weightBattery; // 20.0
    }

    // Critical battery (<= 15%) or battery saver active and discharging
    if (snapshot.isCriticalBattery || snapshot.isBatterySaverActive == true) {
      if (transport == TransportType.ble) {
        return weightBattery; // 20.0 (Lowest power consumption)
      } else if (transport == TransportType.lan) {
        return weightBattery * 0.5; // 10.0 (Moderate Wi-Fi radio power)
      }
      return 0.0;
    }

    // Low battery (15% - 30%) and discharging
    if (snapshot.isLowBattery) {
      if (transport == TransportType.ble) {
        return weightBattery; // 20.0
      } else if (transport == TransportType.lan) {
        return weightBattery * 0.75; // 15.0
      }
    }

    return weightBattery * 0.5;
  }

  /// Scores signal quality and link latency/throughput.
  ///
  /// Strictly avoids fabricating LAN RSSI:
  /// - BLE evaluates physical beacon RSSI.
  /// - LAN evaluates latency/throughput if known, or neutral score if unknown.
  double scoreSignalQuality({
    required TransportType transport,
    required DiscoveredPeer peer,
    LinkMetrics? metrics,
  }) {
    if (transport == TransportType.ble) {
      final rssi = peer.rssi;
      if (rssi >= -60) return weightSignalQuality; // 5.0
      if (rssi >= -75) return weightSignalQuality * 0.6; // 3.0
      if (rssi >= -85) return weightSignalQuality * 0.2; // 1.0
      return 0.0;
    }

    if (transport == TransportType.lan) {
      if (metrics != null && metrics.latencyMs > 0) {
        if (metrics.latencyMs < 20) return weightSignalQuality; // 5.0
        if (metrics.latencyMs < 50) return weightSignalQuality * 0.6; // 3.0
        return weightSignalQuality * 0.2; // 1.0
      }
      // Neutral baseline for LAN when latency is unprobed (no fabricated RSSI)
      return weightSignalQuality * 0.6; // 3.0
    }

    return 0.0;
  }
}
