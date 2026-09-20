import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';

/// Represents a nearby device discovered via radio beacons or network discovery.
class DiscoveredPeer {
  final String deviceId;
  final String displayName;
  final TransportType transportType;
  final int rssi;
  final String? endpointAddress; // IP:Port for LAN, MAC/UUID for Bluetooth
  final DateTime lastSeen;
  final Map<String, dynamic> metadata;

  const DiscoveredPeer({
    required this.deviceId,
    required this.displayName,
    required this.transportType,
    required this.rssi,
    this.endpointAddress,
    required this.lastSeen,
    this.metadata = const {},
  });
}

/// Information broadcast to nearby devices during discovery advertising.
class DeviceAdvertisement {
  final String deviceId;
  final String displayName;
  final Set<TransportType> supportedTransports;
  final int protocolVersion;

  const DeviceAdvertisement({
    required this.deviceId,
    required this.displayName,
    required this.supportedTransports,
    required this.protocolVersion,
  });
}

/// Abstract contract for discovering nearby SiloSend peers and broadcasting local presence.
abstract class DiscoveryService {
  /// The physical transport this discovery service scans on.
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
