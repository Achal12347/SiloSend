import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';

/// Current operational status of a discovery service.
enum DiscoveryStatus {
  /// Discovery service is idle / stopped.
  idle,

  /// Discovery service is initializing or binding sockets/radios.
  starting,

  /// Discovery service is actively scanning and/or advertising.
  active,

  /// Discovery service is shutting down.
  stopping,

  /// Discovery service encountered an error.
  error;

  /// Whether discovery is currently actively running.
  bool get isActive => this == DiscoveryStatus.active;
}

/// Represents a nearby device discovered via radio beacons or network discovery.
///
/// NOTE: Discovery represents an unauthenticated claimed presence ("I claim to be device X").
/// [isIdentityVerified] is strictly `false` during discovery, and only transitions to `true`
/// after the Secure Session layer (Phase 6) cryptographically verifies digital signatures.
class DiscoveredPeer {
  /// The 16-byte hex device identifier claimed by the peer.
  final String deviceId;

  /// User-visible display name claimed in the beacon.
  final String displayName;

  /// The transport on which this peer was most recently observed.
  final TransportType transportType;

  /// All transport media known to be supported by this peer (e.g. {lan, ble}).
  final Set<TransportType> availableTransports;

  /// Signal strength indicator (or 0 for LAN).
  final int rssi;

  /// Network or radio endpoint (IP:Port for LAN, MAC/UUID for BLE).
  final String? endpointAddress;

  /// Timestamp when the most recent beacon was received from this peer.
  final DateTime lastSeen;

  /// Whether this peer's identity has been cryptographically verified via Secure Session.
  /// Strictly `false` during discovery.
  final bool isIdentityVerified;

  /// Optional extra metadata advertised by the peer.
  final Map<String, dynamic> metadata;

  DiscoveredPeer({
    required this.deviceId,
    required this.displayName,
    required this.transportType,
    Set<TransportType>? availableTransports,
    required this.rssi,
    this.endpointAddress,
    required this.lastSeen,
    this.isIdentityVerified = false,
    this.metadata = const {},
  }) : availableTransports = availableTransports ?? {transportType};

  DiscoveredPeer copyWith({
    String? deviceId,
    String? displayName,
    TransportType? transportType,
    Set<TransportType>? availableTransports,
    int? rssi,
    String? endpointAddress,
    DateTime? lastSeen,
    bool? isIdentityVerified,
    Map<String, dynamic>? metadata,
  }) {
    return DiscoveredPeer(
      deviceId: deviceId ?? this.deviceId,
      displayName: displayName ?? this.displayName,
      transportType: transportType ?? this.transportType,
      availableTransports: availableTransports ?? this.availableTransports,
      rssi: rssi ?? this.rssi,
      endpointAddress: endpointAddress ?? this.endpointAddress,
      lastSeen: lastSeen ?? this.lastSeen,
      isIdentityVerified: isIdentityVerified ?? this.isIdentityVerified,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// Information broadcast to nearby devices during discovery advertising.
class DeviceAdvertisement {
  final String deviceId;
  final String displayName;
  final int port;
  final Set<TransportType> supportedTransports;
  final int protocolVersion;

  const DeviceAdvertisement({
    required this.deviceId,
    required this.displayName,
    this.port = 53531,
    required this.supportedTransports,
    required this.protocolVersion,
  });
}

/// Abstract contract for discovering nearby SiloSend peers and broadcasting local presence.
abstract class DiscoveryService {
  /// The physical transport this discovery service operates on.
  TransportType get transportType;

  /// Stream of peers discovered in proximity.
  Stream<DiscoveredPeer> get discoveredPeers;

  /// Starts scanning for nearby SiloSend devices.
  Future<void> startDiscovery();

  /// Stops the active discovery scan.
  Future<void> stopDiscovery();

  /// Starts advertising this device's presence to nearby devices.
  Future<void> startAdvertising(DeviceAdvertisement advertisement);

  /// Stops advertising this device.
  Future<void> stopAdvertising();
}
