import 'package:silosend_datasharing_app/core/contracts/security_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';

/// Metadata and state for an active point-to-point connection session.
class ConnectionSessionInfo {
  final String sessionId;
  final String remoteDeviceId;
  final TransportType activeTransport;
  final SessionState state;
  final DateTime establishedAt;
  final int bytesSent;
  final int bytesReceived;

  const ConnectionSessionInfo({
    required this.sessionId,
    required this.remoteDeviceId,
    required this.activeTransport,
    required this.state,
    required this.establishedAt,
    this.bytesSent = 0,
    this.bytesReceived = 0,
  });

  ConnectionSessionInfo copyWith({
    String? sessionId,
    String? remoteDeviceId,
    TransportType? activeTransport,
    SessionState? state,
    DateTime? establishedAt,
    int? bytesSent,
    int? bytesReceived,
  }) {
    return ConnectionSessionInfo(
      sessionId: sessionId ?? this.sessionId,
      remoteDeviceId: remoteDeviceId ?? this.remoteDeviceId,
      activeTransport: activeTransport ?? this.activeTransport,
      state: state ?? this.state,
      establishedAt: establishedAt ?? this.establishedAt,
      bytesSent: bytesSent ?? this.bytesSent,
      bytesReceived: bytesReceived ?? this.bytesReceived,
    );
  }
}
