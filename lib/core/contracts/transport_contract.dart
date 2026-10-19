import 'dart:typed_data';

/// Enumerates the physical / radio transports supported by Vayu.
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

  /// Nothing measured. A 0 latency or RSSI always means "unknown".
  static const zero = LinkMetrics(
    latencyMs: 0,
    estimatedThroughputBytesPerSec: 0,
    rssi: 0,
  );
}

/// Represents the lifecycle state of an active physical transport connection.
enum ConnectionState {
  connecting,
  connected,
  disconnecting,
  disconnected,
  failed,
}

/// Abstract contract representing a bidirectional connection link to a peer device.
///
/// Concrete implementations exist per platform (e.g. Android BLE, Wi-Fi Direct, LAN sockets).
abstract class TransportConnection {
  /// Unique identifier for this connection instance.
  String get connectionId;

  /// The physical transport medium used by this connection.
  TransportType get type;

  /// The current lifecycle state of this transport connection.
  ConnectionState get state;

  /// Whether the connection is currently open and healthy.
  bool get isConnected => state == ConnectionState.connected;

  /// Optional remote endpoint address (e.g. IPv4 string or BLE MAC/UUID).
  String? get remoteAddress;

  /// Optional remote port (e.g. TCP port for LAN).
  int? get remotePort;

  /// Optional reason recorded when the link disconnected or failed.
  String? get disconnectReason;

  /// Stream of raw incoming byte chunks received over this link.
  Stream<Uint8List> get incomingBytes;

  /// Sends raw bytes over this connection link.
  Future<void> sendBytes(Uint8List data);

  /// Closes the physical link and releases OS socket/radio resources.
  Future<void> close({String? reason});

  /// The latest real-time link quality metrics.
  LinkMetrics get currentMetrics;
}
