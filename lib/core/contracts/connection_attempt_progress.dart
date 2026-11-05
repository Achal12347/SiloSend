import 'package:vayu/core/contracts/transport_contract.dart';

/// Progress of one outbound connection attempt. Stages are for the app and its
/// logs; people see only [text], since which radio is being tried along the
/// way is not theirs to act on. The route is shown once the transfer runs.
enum ConnectionAttemptStage {
  evaluating,
  connecting,
  handingOff,
  joining,
  securing,
  fallback,
  connected,
  failed,
}

class ConnectionAttemptProgress {
  final String peerId;
  final String peerName;
  final ConnectionAttemptStage stage;
  final TransportType? transport;

  const ConnectionAttemptProgress({
    required this.peerId,
    required this.peerName,
    required this.stage,
    this.transport,
  });

  String get text => stage == ConnectionAttemptStage.failed
      ? "Couldn't connect to $peerName. Move closer and try again."
      : 'Connecting to $peerName…';
}
