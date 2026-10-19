import 'dart:async';

import 'package:flutter/services.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/discovery/discovery_beacon.dart';

/// Bluetooth Low Energy (BLE) peer discovery service.
///
/// Discovers nearby Vayu devices via BLE advertisements containing compact [DiscoveryBeacon] frames.
/// Communicates with native platform channels on Android (and desktop platform adapters when available).
class BleDiscoveryService implements DiscoveryService {
  static const String channelName = 'com.achyrio.vayu/ble_discovery';
  static const String eventChannelName = 'com.achyrio.vayu/ble_scan_events';
  static const String vayuServiceUuid = '00005353-0000-1000-8000-00805f9b34fb';

  final String localDeviceId;
  final MethodChannel _methodChannel;
  final EventChannel? _eventChannel;
  final _peerController = StreamController<DiscoveredPeer>.broadcast();

  StreamSubscription? _eventSubscription;
  bool _isScanning = false;
  bool _isAdvertising = false;
  DeviceAdvertisement? _currentAdvertisement;

  BleDiscoveryService({
    required this.localDeviceId,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel = methodChannel ?? const MethodChannel(channelName),
       _eventChannel = eventChannel ?? const EventChannel(eventChannelName);

  @override
  TransportType get transportType => TransportType.ble;

  @override
  Stream<DiscoveredPeer> get discoveredPeers => _peerController.stream;

  bool _batterySaver = false;

  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;

  /// Sets battery saver mode and dynamically reapplies radio power settings.
  void setBatterySaver(bool enabled) {
    if (_batterySaver == enabled) return;
    _batterySaver = enabled;
    if (_isScanning) {
      stopDiscovery().then((_) => startDiscovery());
    }
    if (_isAdvertising && _currentAdvertisement != null) {
      final ad = _currentAdvertisement!;
      stopAdvertising().then((_) => startAdvertising(ad));
    }
  }

  @override
  Future<void> startDiscovery() async {
    if (_isScanning) return;
    AppLogger.info(
      'BleDiscoveryService',
      'Starting BLE discovery scanning (batterySaver: $_batterySaver)...',
    );

    try {
      _startListeningToScanEvents();
      await _methodChannel.invokeMethod('startScan', {
        'serviceUuid': vayuServiceUuid,
        'batterySaver': _batterySaver,
      });
      _isScanning = true;
      AppLogger.info('BleDiscoveryService', 'BLE discovery scanning active');
    } on PlatformException catch (e) {
      AppLogger.warning(
        'BleDiscoveryService',
        'Failed to start BLE scan: ${e.message} (Code: ${e.code})',
      );
      _isScanning = false;
    } on MissingPluginException {
      AppLogger.warning(
        'BleDiscoveryService',
        'BLE platform channel not available on this platform/configuration',
      );
      _isScanning = false;
    } catch (e, stack) {
      AppLogger.error(
        'BleDiscoveryService',
        'Unexpected error starting BLE scan',
        error: e,
        stackTrace: stack,
      );
      _isScanning = false;
    }
  }

  @override
  Future<void> stopDiscovery() async {
    if (!_isScanning) return;
    try {
      await _methodChannel.invokeMethod('stopScan');
    } catch (_) {}
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _isScanning = false;
    AppLogger.info('BleDiscoveryService', 'Stopped BLE discovery scanning');
  }

  @override
  Future<void> startAdvertising(DeviceAdvertisement advertisement) async {
    _currentAdvertisement = advertisement;

    try {
      final beacon = DiscoveryBeacon(
        deviceId: _hexToBytes(advertisement.deviceId),
        port: advertisement.port,
        supportedTransports: advertisement.supportedTransports,
        displayName: advertisement.displayName,
        protocolVersion: advertisement.protocolVersion,
        hosting: advertisement.hosting,
        hostingPrivate: advertisement.hostingPrivate,
        relaying: advertisement.relaying,
      );

      final beaconBytes = beacon.toBytes(
        maxNameBytes: DiscoveryBeacon.maxBleDisplayNameBytes,
      );

      await _methodChannel.invokeMethod('startAdvertising', {
        'serviceUuid': vayuServiceUuid,
        'beaconBytes': beaconBytes,
        'batterySaver': _batterySaver,
      });

      _isAdvertising = true;
      AppLogger.info(
        'BleDiscoveryService',
        'Started BLE discovery advertising for: ${advertisement.displayName}',
      );
    } on PlatformException catch (e) {
      AppLogger.warning(
        'BleDiscoveryService',
        'Failed to start BLE advertising: ${e.message} (Code: ${e.code})',
      );
      _isAdvertising = false;
    } on MissingPluginException {
      AppLogger.warning(
        'BleDiscoveryService',
        'BLE advertising platform channel not available on this platform/configuration',
      );
      _isAdvertising = false;
    } catch (e, stack) {
      AppLogger.error(
        'BleDiscoveryService',
        'Unexpected error starting BLE advertising',
        error: e,
        stackTrace: stack,
      );
      _isAdvertising = false;
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    try {
      await _methodChannel.invokeMethod('stopAdvertising');
    } catch (_) {}
    _isAdvertising = false;
    _currentAdvertisement = null;
    AppLogger.info('BleDiscoveryService', 'Stopped BLE discovery advertising');
  }

  void _startListeningToScanEvents() {
    final channel = _eventChannel;
    if (_eventSubscription != null || channel == null) return;

    try {
      _eventSubscription = channel.receiveBroadcastStream().listen(
        _handleScanEvent,
        onError: (e) {
          AppLogger.warning(
            'BleDiscoveryService',
            'Scan stream error',
            error: e,
          );
        },
      );
    } catch (e) {
      AppLogger.warning(
        'BleDiscoveryService',
        'Could not attach scan event listener',
        error: e,
      );
    }
  }

  /// Processes raw scan results emitted by platform scanner.
  ///
  /// Can also be called directly by tests or mock platform adapters.
  void handleRawScanResult({
    required Uint8List rawBeaconBytes,
    required int rssi,
    String? deviceAddress,
  }) {
    try {
      final beacon = DiscoveryBeacon.fromBytes(rawBeaconBytes);

      // Self-advertisement filter
      if (beacon.deviceIdHex.toLowerCase() == localDeviceId.toLowerCase()) {
        return;
      }

      final peer = DiscoveredPeer(
        deviceId: beacon.deviceIdHex,
        displayName: beacon.displayName,
        transportType: TransportType.ble,
        availableTransports: beacon.supportedTransports,
        rssi: rssi,
        endpointAddress: deviceAddress,
        transportEndpoints: {
          if (deviceAddress != null && deviceAddress.isNotEmpty)
            TransportType.ble: deviceAddress,
        },
        lastSeen: DateTime.now(),
        metadata: {
          'hosting': beacon.hosting,
          'private': beacon.hostingPrivate,
          'relay': beacon.relaying,
        },
        isIdentityVerified: false, // Strictly unverified at discovery
      );

      _peerController.add(peer);
    } catch (e) {
      AppLogger.debug('BleDiscoveryService', 'Ignored invalid BLE beacon: $e');
    }
  }

  void _handleScanEvent(dynamic event) {
    if (event is! Map) return;

    final rawBytes = event['beaconBytes'];
    final rssi = event['rssi'] as int? ?? -100;
    final address = event['address'] as String?;

    if (rawBytes is List<int>) {
      handleRawScanResult(
        rawBeaconBytes: Uint8List.fromList(rawBytes),
        rssi: rssi,
        deviceAddress: address,
      );
    }
  }

  Uint8List _hexToBytes(String hex) {
    final cleanHex = hex.replaceAll('-', '').trim();
    if (cleanHex.length != 32) {
      throw ArgumentError('Invalid hex deviceId length: ${cleanHex.length}');
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
