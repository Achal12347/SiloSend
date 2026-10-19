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
  chatFileOffer(0x22),
  chatFileAnswer(0x23),
  hostCatalogRequest(0x50),
  hostCatalog(0x51),
  hostDownloadRequest(0x52),
  hostDownloadResponse(0x53),
  hostEnded(0x54),
  relayOpen(0x60),
  relayOpened(0x61),
  relayData(0x62),
  relayClose(0x63),
  reachQuery(0x64),
  reachAnswer(0x65),
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
