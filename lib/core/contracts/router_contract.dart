import 'package:vayu/domain/protocol/vayu_packet.dart';

/// Abstract contract for routing packets directly or relaying them across mesh nodes.
///
/// Ensures routing nodes only inspect the outer header and never access inner plaintext.
abstract class PacketRouter {
  /// Routes an outbound packet towards its destination (directly or via next hop).
  Future<void> routeOutboundPacket(VayuPacket packet);

  /// Stream of decrypted/verified inbound packets addressed to this local device.
  Stream<VayuPacket> get inboundPacketsForMe;

  /// Handles an inbound raw packet received from a transport link.
  ///
  /// If addressed to this device, passes to [inboundPacketsForMe].
  /// If addressed to a remote device, evaluates relay eligibility and forwards it.
  Future<void> handleInboundPacket(VayuPacket packet);
}
