import 'dart:async';

import 'package:silosend_datasharing_app/core/connection/packet_framing.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';

/// Decorates a [TransportConnection] with typed packet stream framing and serialization.
class FramedTransportConnection {
  final TransportConnection rawConnection;
  late final Stream<SiloSendPacket> _packetStream;

  FramedTransportConnection(this.rawConnection) {
    _packetStream = rawConnection.incomingBytes
        .transform(PacketStreamTransformer())
        .asBroadcastStream();
  }

  String get connectionId => rawConnection.connectionId;
  TransportType get type => rawConnection.type;
  ConnectionState get state => rawConnection.state;
  bool get isConnected => rawConnection.isConnected;
  String? get remoteAddress => rawConnection.remoteAddress;
  int? get remotePort => rawConnection.remotePort;
  String? get disconnectReason => rawConnection.disconnectReason;
  LinkMetrics get currentMetrics => rawConnection.currentMetrics;

  /// Stream of discrete, CRC-verified [SiloSendPacket] objects received from the peer.
  Stream<SiloSendPacket> get incomingPackets => _packetStream;

  /// Serializes and transmits a [SiloSendPacket] across the physical transport link.
  Future<void> sendPacket(SiloSendPacket packet) async {
    final bytes = packet.toBytes();
    await rawConnection.sendBytes(bytes);
  }

  /// Closes the underlying physical connection.
  Future<void> close({String? reason}) async {
    await rawConnection.close(reason: reason);
  }
}
