import 'package:vayu/core/contracts/transport_contract.dart';

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

/// High-level product operational state of discovery.
enum DiscoveryOperationalState {
  /// Discovery has not been started yet.
  idle,

  /// Actively broadcasting beacons and searching on active transports.
  searching,

  /// One or more nearby devices have been discovered and are ready to share.
  ready,

  /// Active scan has not found any nearby devices yet.
  noDevices,

  /// Discovery cannot proceed until a required capability or transport is enabled.
  actionRequired,
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

  /// Transport-specific endpoints (LAN IP:Port, BLE Address, etc.).
  final Map<TransportType, String> transportEndpoints;

  /// Timestamp when the most recent beacon was received from this peer.
  final DateTime lastSeen;

  /// Whether this peer's identity has been cryptographically verified via Secure Session.
  /// Strictly `false` during discovery.
  final bool isIdentityVerified;

  /// Optional extra metadata advertised by the peer.
  final Map<String, dynamic> metadata;

  /// The phone announces it is hosting files (Host & Client), as heard in
  /// its latest beacon.
  bool get isHosting => metadata['hosting'] == true;

  /// Its share needs a PIN (as heard in its latest beacon).
  bool get isHostingPrivate => isHosting && metadata['private'] == true;

  /// It relays connections for nearby phones (mesh).
  bool get isRelaying => metadata['relay'] == true;

  DiscoveredPeer({
    required this.deviceId,
    required this.displayName,
    required this.transportType,
    Set<TransportType>? availableTransports,
    required this.rssi,
    String? endpointAddress,
    Map<TransportType, String>? transportEndpoints,
    required this.lastSeen,
    this.isIdentityVerified = false,
    this.metadata = const {},
  }) : availableTransports = availableTransports ?? {transportType},
       transportEndpoints = transportEndpoints != null
           ? Map<TransportType, String>.unmodifiable(transportEndpoints)
           : (endpointAddress != null
                 ? Map<TransportType, String>.unmodifiable({
                     transportType: endpointAddress,
                   })
                 : const {});

  /// Network or radio endpoint for the primary observed [transportType].
  String? get endpointAddress => transportEndpoints[transportType];

  /// Specifically retrieves the LAN endpoint (IP:Port), if discovered.
  String? get lanEndpoint => transportEndpoints[TransportType.lan];

  /// Specifically retrieves the BLE device address, if discovered.
  String? get bleEndpoint => transportEndpoints[TransportType.ble];

  DiscoveredPeer copyWith({
    String? deviceId,
    String? displayName,
    TransportType? transportType,
    Set<TransportType>? availableTransports,
    int? rssi,
    String? endpointAddress,
    Map<TransportType, String>? transportEndpoints,
    DateTime? lastSeen,
    bool? isIdentityVerified,
    Map<String, dynamic>? metadata,
  }) {
    final effectiveTransport = transportType ?? this.transportType;
    final effectiveEndpoints = transportEndpoints != null
        ? Map<TransportType, String>.from(transportEndpoints)
        : Map<TransportType, String>.from(this.transportEndpoints);
    if (endpointAddress != null) {
      effectiveEndpoints[effectiveTransport] = endpointAddress;
    }

    return DiscoveredPeer(
      deviceId: deviceId ?? this.deviceId,
      displayName: displayName ?? this.displayName,
      transportType: effectiveTransport,
      availableTransports: availableTransports ?? this.availableTransports,
      rssi: rssi ?? this.rssi,
      transportEndpoints: effectiveEndpoints,
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

  /// This phone is hosting files (Host & Client).
  final bool hosting;

  /// Its share needs a PIN.
  final bool hostingPrivate;

  /// It relays connections for nearby phones (mesh).
  final bool relaying;

  const DeviceAdvertisement({
    required this.deviceId,
    required this.displayName,
    this.port = 53531,
    required this.supportedTransports,
    required this.protocolVersion,
    this.hosting = false,
    this.hostingPrivate = false,
    this.relaying = false,
  });
}

/// Abstract contract for discovering nearby Vayu peers and broadcasting local presence.
abstract class DiscoveryService {
  /// The physical transport this discovery service operates on.
  TransportType get transportType;

  /// Stream of peers discovered in proximity.
  Stream<DiscoveredPeer> get discoveredPeers;

  /// Starts scanning for nearby Vayu devices.
  Future<void> startDiscovery();

  /// Stops the active discovery scan.
  Future<void> stopDiscovery();

  /// Starts advertising this device's presence to nearby devices.
  Future<void> startAdvertising(DeviceAdvertisement advertisement);

  /// Stops advertising this device.
  Future<void> stopAdvertising();
}
