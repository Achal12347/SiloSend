import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';

/// Metadata and state for an active point-to-point connection session.
class ConnectionSessionInfo {
  final String sessionId;
  final String remoteDeviceId;
  final String? remoteDisplayName;
  final String? remotePlatform;
  final TransportType activeTransport;
  final SessionState state;
  final DateTime establishedAt;
  final int bytesSent;
  final int bytesReceived;
  final String? remoteAddress;
  final int? remotePort;
  final bool isInitiator;

  /// Optional protocol features the remote build advertised in its handshake.
  final Set<String> remoteFeatures;

  const ConnectionSessionInfo({
    required this.sessionId,
    required this.remoteDeviceId,
    this.remoteDisplayName,
    this.remotePlatform,
    required this.activeTransport,
    required this.state,
    required this.establishedAt,
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.remoteAddress,
    this.remotePort,
    this.isInitiator = false,
    this.remoteFeatures = const {},
  });

  /// The route this session really uses: `lan`, `wifiDirect`, `ble` or
  /// `relay`. Wi-Fi Direct is TCP too, so it is told apart by the subnet
  /// Android gives its groups.
  String get routeName =>
      activeTransport == TransportType.lan &&
          (remoteAddress?.startsWith('192.168.49.') ?? false)
      ? 'wifiDirect'
      : activeTransport.name;

  ConnectionSessionInfo copyWith({
    String? sessionId,
    String? remoteDeviceId,
    String? remoteDisplayName,
    String? remotePlatform,
    TransportType? activeTransport,
    SessionState? state,
    DateTime? establishedAt,
    int? bytesSent,
    int? bytesReceived,
    String? remoteAddress,
    int? remotePort,
    bool? isInitiator,
    Set<String>? remoteFeatures,
  }) {
    return ConnectionSessionInfo(
      sessionId: sessionId ?? this.sessionId,
      remoteDeviceId: remoteDeviceId ?? this.remoteDeviceId,
      remoteDisplayName: remoteDisplayName ?? this.remoteDisplayName,
      remotePlatform: remotePlatform ?? this.remotePlatform,
      activeTransport: activeTransport ?? this.activeTransport,
      state: state ?? this.state,
      establishedAt: establishedAt ?? this.establishedAt,
      bytesSent: bytesSent ?? this.bytesSent,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      remoteAddress: remoteAddress ?? this.remoteAddress,
      remotePort: remotePort ?? this.remotePort,
      isInitiator: isInitiator ?? this.isInitiator,
      remoteFeatures: remoteFeatures ?? this.remoteFeatures,
    );
  }
}
