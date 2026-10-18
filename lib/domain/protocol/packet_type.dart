/// Identifies the high-level intent of a binary Vayu wire frame.
enum PacketType {
  handshakeInit(0x01),
  handshakeResponse(0x02),
  authExchange(0x03),
  transferMetadata(0x10),
  transferChunk(0x11),
  transferAck(0x12),
  transferNack(0x13),
  transferCancel(0x14),
  transferBatchOffer(0x15),
  transferBatchResponse(0x16),
  transferDigest(0x17),
  chatMessage(0x20),
  chatDeliveryAck(0x21),
  linkUpgradeRequest(0x40),
  linkUpgradeResponse(0x41),
  ping(0x30),
  pong(0x31),
  sessionTeardown(0xFF);

  final int code;
  const PacketType(this.code);

  static PacketType fromCode(int code) {
    for (final type in PacketType.values) {
      if (type.code == code) return type;
    }
    throw FormatException(
      'Unknown packet type code: 0x${code.toRadixString(16)}',
    );
  }
}
