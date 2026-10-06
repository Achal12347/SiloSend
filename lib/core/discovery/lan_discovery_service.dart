import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/discovery/discovery_beacon.dart';

/// Pure Dart implementation of LAN peer discovery using dual-path UDP multicast and broadcast.
///
/// Features:
/// - Listens on standard administrative multicast group `239.255.77.88:53530` and subnet broadcast.
/// - Filters out own self-broadcast beacons using local device ID.
/// - Defensive against malformed and truncated network frames.
/// - Compatible with Android and Windows (`reusePort: !Platform.isWindows`).
class LanDiscoveryService implements DiscoveryService {
  static const int discoveryPort = 53530;
  static const String multicastAddressStr = '239.255.77.88';

  final String localDeviceId;
  final _peerController = StreamController<DiscoveredPeer>.broadcast();

  RawDatagramSocket? _socket;
  Timer? _advertisementTimer;
  DeviceAdvertisement? _currentAdvertisement;
  bool _isScanning = false;
  bool _isAdvertising = false;

  LanDiscoveryService({required this.localDeviceId});

  @override
  TransportType get transportType => TransportType.lan;

  @override
  Stream<DiscoveredPeer> get discoveredPeers => _peerController.stream;

  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;

  @override
  Future<void> startDiscovery() async {
    if (_isScanning) return;
    AppLogger.info('LanDiscoveryService', 'Starting LAN discovery scanning...');
    await _ensureSocketBound();
    _isScanning = true;
  }

  @override
  Future<void> stopDiscovery() async {
    _isScanning = false;
    AppLogger.info('LanDiscoveryService', 'Stopped LAN discovery scanning');
    if (!_isAdvertising) {
      _closeSocket();
    }
  }

  @override
  Future<void> startAdvertising(DeviceAdvertisement advertisement) async {
    _currentAdvertisement = advertisement;
    _isAdvertising = true;
    await _ensureSocketBound();

    _advertisementTimer?.cancel();
    _broadcastBeacon(); // Send immediate beacon
    _advertisementTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _broadcastBeacon(),
    );
    AppLogger.info(
      'LanDiscoveryService',
      'Started LAN discovery advertising for: ${advertisement.displayName}',
    );
  }

  @override
  Future<void> stopAdvertising() async {
    _isAdvertising = false;
    _advertisementTimer?.cancel();
    _advertisementTimer = null;
    _currentAdvertisement = null;
    AppLogger.info('LanDiscoveryService', 'Stopped LAN discovery advertising');
    if (!_isScanning) {
      _closeSocket();
    }
  }

  Future<void> _ensureSocketBound() async {
    if (_socket != null) return;

    try {
      // Windows Win32 API does not support SO_REUSEPORT (causes Dart Socket ERROR).
      // Android / Linux benefit from reusePort to allow multiple instances.
      final bool reusePort = !Platform.isWindows;

      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: reusePort,
      );

      _socket!.broadcastEnabled = true;

      // Join multicast group on default and each active network interface
      try {
        final mcastGroup = InternetAddress(multicastAddressStr);
        try {
          _socket!.joinMulticast(mcastGroup);
        } catch (_) {}

        try {
          final interfaces = await NetworkInterface.list(
            includeLoopback: false,
            type: InternetAddressType.IPv4,
          );
          for (final iface in interfaces) {
            try {
              _socket!.joinMulticast(mcastGroup, iface);
            } catch (_) {}
          }
        } catch (_) {}
      } catch (e) {
        AppLogger.warning(
          'LanDiscoveryService',
          'Failed to join multicast group, broadcast will be used as fallback',
          error: e,
        );
      }

      _socket!.listen(
        _handleSocketEvent,
        onError: (e) {
          AppLogger.error(
            'LanDiscoveryService',
            'Socket error encountered',
            error: e,
          );
        },
      );
    } catch (e, stack) {
      AppLogger.error(
        'LanDiscoveryService',
        'Failed to bind LAN discovery socket on port $discoveryPort',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _socket == null) return;

    final datagram = _socket!.receive();
    if (datagram == null || !_isScanning) return;

    handleIncomingPacket(Uint8List.fromList(datagram.data), datagram.address);
  }

  /// Processes raw packet bytes received from the network.
  ///
  /// Can also be called directly by tests or network adapters.
  void handleIncomingPacket(Uint8List data, InternetAddress sourceAddress) {
    if (!_isScanning) return;

    try {
      final beacon = DiscoveryBeacon.fromBytes(data);

      // Strictly filter out self-broadcasts
      if (beacon.deviceIdHex.toLowerCase() == localDeviceId.toLowerCase()) {
        return;
      }

      final lanEndpoint = '${sourceAddress.address}:${beacon.port}';
      final peer = DiscoveredPeer(
        deviceId: beacon.deviceIdHex,
        displayName: beacon.displayName,
        transportType: TransportType.lan,
        availableTransports: beacon.supportedTransports,
        rssi: 0, // RSSI is not applicable for wired/LAN UDP
        endpointAddress: lanEndpoint,
        lastSeen: DateTime.now(),
        isIdentityVerified: false, // Strictly unverified at discovery stage
        transportEndpoints: {TransportType.lan: lanEndpoint},
      );

      _peerController.add(peer);
    } catch (e) {
      // Malformed or foreign packets on the port are safely ignored per defensive networking rule
      AppLogger.debug(
        'LanDiscoveryService',
        'Ignored invalid packet from ${sourceAddress.address}: $e',
      );
    }
  }

  Future<void> _broadcastBeacon() async {
    if (_socket == null || _currentAdvertisement == null) return;

    try {
      final ad = _currentAdvertisement!;
      final beacon = DiscoveryBeacon(
        deviceId: _hexToBytes(ad.deviceId),
        port: ad.port,
        supportedTransports: ad.supportedTransports,
        displayName: ad.displayName,
        protocolVersion: ad.protocolVersion,
      );

      final bytes = beacon.toBytes();

      // 1. Multicast dispatch
      try {
        final mcastGroup = InternetAddress(multicastAddressStr);
        _socket!.send(bytes, mcastGroup, discoveryPort);
      } catch (_) {}

      // 2. Global subnet broadcast dispatch
      try {
        final broadcastAddr = InternetAddress('255.255.255.255');
        _socket!.send(bytes, broadcastAddr, discoveryPort);
      } catch (_) {}

      // 3. Directed subnet broadcast dispatch for each active interface (e.g. 192.168.1.255, 192.168.43.255)
      try {
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          type: InternetAddressType.IPv4,
        );
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              final parts = addr.address.split('.');
              if (parts.length == 4) {
                final subnetBcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
                try {
                  _socket!.send(
                    bytes,
                    InternetAddress(subnetBcast),
                    discoveryPort,
                  );
                } catch (_) {}
              }
            }
          }
        }
      } catch (_) {}
    } catch (e) {
      AppLogger.warning(
        'LanDiscoveryService',
        'Error dispatching beacon broadcast',
        error: e,
      );
    }
  }

  void _closeSocket() {
    _socket?.close();
    _socket = null;
  }

  Uint8List _hexToBytes(String hex) {
    final cleanHex = hex.replaceAll('-', '').trim();
    if (cleanHex.length != 32) {
      throw ArgumentError(
        'Invalid hex deviceId length: ${cleanHex.length} (expected 32)',
      );
    }
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(cleanHex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  void dispose() {
    stopAdvertising();
    stopDiscovery();
    _peerController.close();
  }
}
