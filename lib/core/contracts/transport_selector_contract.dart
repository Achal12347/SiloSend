import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';

/// Request parameters for evaluating and selecting an optimal transport.
class TransportSelectionRequest {
  /// The discovered remote peer target.
  final DiscoveredPeer targetPeer;

  /// Total size of the payload to transfer in bytes, or 0 if opening a general session.
  final int payloadSizeBytes;

  /// Optional payload type (file, contact, message, rawStream).
  final PayloadType? payloadType;

  /// Optional explicit caller preference override.
  final TransportType? preferredTransport;

  /// Whether device battery and power state should be considered during scoring.
  final bool batteryAware;

  const TransportSelectionRequest({
    required this.targetPeer,
    this.payloadSizeBytes = 0,
    this.payloadType,
    this.preferredTransport,
    this.batteryAware = true,
  });

  @override
  String toString() =>
      'TransportSelectionRequest(peer: ${targetPeer.displayName} [${targetPeer.deviceId}], bytes: $payloadSizeBytes, type: $payloadType, pref: $preferredTransport, batteryAware: $batteryAware)';
}

/// Evaluated score and eligibility for a candidate transport medium.
class TransportCandidateScore {
  /// The candidate transport type.
  final TransportType transport;

  /// Evaluated composite score (0.0 to 100.0). Higher is better.
  final double score;

  /// Whether this transport is viable and eligible for connection.
  final bool isAvailable;

  /// If disqualified, the specific deterministic reason.
  final String? disqualifyReason;

  /// Detailed factor breakdown contributing to [score].
  final Map<String, double> factors;

  const TransportCandidateScore({
    required this.transport,
    required this.score,
    required this.isAvailable,
    this.disqualifyReason,
    this.factors = const {},
  });

  @override
  String toString() =>
      'CandidateScore(${transport.name}: score=${score.toStringAsFixed(1)}, available=$isAvailable${disqualifyReason != null ? ', reason=$disqualifyReason' : ''})';
}

/// Final decision produced by the [TransportSelector].
class TransportSelectionResult {
  /// The highest-ranking available transport chosen for primary connection.
  final TransportType selectedTransport;

  /// All candidate transports evaluated, sorted by score descending.
  final List<TransportCandidateScore> rankedCandidates;

  /// Prioritized fallback transports in descending score order (excluding [selectedTransport]).
  final List<TransportType> fallbackChain;

  /// Human-readable, sanitized explanation of the decision.
  final String rationale;

  const TransportSelectionResult({
    required this.selectedTransport,
    required this.rankedCandidates,
    required this.fallbackChain,
    required this.rationale,
  });

  @override
  String toString() =>
      'TransportSelectionResult(selected: ${selectedTransport.name}, fallbacks: ${fallbackChain.map((t) => t.name).toList()}, rationale: "$rationale")';
}

/// Thrown when no candidate transport satisfies the requirements or when all fallbacks fail.
class NoViableTransportException implements Exception {
  final String message;
  final List<TransportCandidateScore> candidateScores;
  final List<String> attemptErrors;

  const NoViableTransportException(
    this.message, {
    this.candidateScores = const [],
    this.attemptErrors = const [],
  });

  @override
  String toString() {
    final buffer = StringBuffer('NoViableTransportException: $message');
    if (attemptErrors.isNotEmpty) {
      buffer.write('\nAttempts: ${attemptErrors.join('; ')}');
    }
    return buffer.toString();
  }
}

/// Headless, UI-independent service that evaluates available transports,
/// ranks candidates using multi-criteria heuristics, and coordinates fallback.
abstract class TransportSelector {
  /// Evaluates the given request and returns ranked candidate transports.
  Future<TransportSelectionResult> selectTransport(
    TransportSelectionRequest request,
  );

  /// Coordinates smart transport selection, attempts connection on the chosen transport,
  /// completes authenticated [SecureSession] elevation, and seamlessly executes the
  /// fallback chain if failures occur.
  Future<SecureSession> connectWithSmartSelection(
    DiscoveredPeer peer, {
    TransportSelectionRequest? request,
    Duration? timeout,
  });
}
