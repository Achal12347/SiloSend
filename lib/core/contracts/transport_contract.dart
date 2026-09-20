import 'dart:typed_data';

/// Enumerates the physical / radio transports supported by SiloSend.
enum TransportType { ble, wifiDirect, lan }

/// Dynamic quality and speed metrics for an active transport link.
class LinkMetrics {
  final int latencyMs;
  final int estimatedThroughputBytesPerSec;
  final int rssi;
  final bool isCongested;

  const LinkMetrics({
    required this.latencyMs,
    required this.estimatedThroughputBytesPerSec,
    required this.rssi,
    this.isCongested = false,
  });

  static const zero = LinkMetrics(
    latencyMs: 0,
    estimatedThroughputBytesPerSec: 0,
    rssi: 0,
  );
}

/// Abstract contract representing a bidirectional connection link to a peer device.
///
/// Concrete implementations exist per platform (e.g. Android BLE, Wi-Fi Direct, LAN sockets).
abstract class TransportConnection {
  /// Unique identifier for this connection instance.
  String get connectionId;

  /// The physical transport medium used by this connection.
  TransportType get type;

  /// Whether the connection is currently open and healthy.
  bool get isConnected;

  /// Stream of raw incoming byte chunks received over this link.
  Stream<Uint8List> get incomingBytes;

  /// Sends raw bytes over this connection link.
  Future<void> sendBytes(Uint8List data);

  /// Closes the physical link and releases OS socket/radio resources.
  Future<void> close();

  /// The latest real-time link quality metrics.
  LinkMetrics get currentMetrics;
}
