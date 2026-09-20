import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';

/// Represents a verified nearby SiloSend peer device.
///
/// Per AI/AGENTS.md, instances must be created from actual discovery results,
/// never fake or simulated data.
class PeerDevice {
  final String id;
  final String displayName;
  final int rssi;
  final Set<TransportType> availableTransports;
  final DateTime lastSeen;
  final bool isPaired;
  final bool isConnected;

  const PeerDevice({
    required this.id,
    required this.displayName,
    required this.rssi,
    required this.availableTransports,
    required this.lastSeen,
    this.isPaired = false,
    this.isConnected = false,
  });

  PeerDevice copyWith({
    String? id,
    String? displayName,
    int? rssi,
    Set<TransportType>? availableTransports,
    DateTime? lastSeen,
    bool? isPaired,
    bool? isConnected,
  }) {
    return PeerDevice(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      rssi: rssi ?? this.rssi,
      availableTransports: availableTransports ?? this.availableTransports,
      lastSeen: lastSeen ?? this.lastSeen,
      isPaired: isPaired ?? this.isPaired,
      isConnected: isConnected ?? this.isConnected,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'rssi': rssi,
    'availableTransports': availableTransports.map((t) => t.name).toList(),
    'lastSeen': lastSeen.toIso8601String(),
    'isPaired': isPaired,
    'isConnected': isConnected,
  };
}
