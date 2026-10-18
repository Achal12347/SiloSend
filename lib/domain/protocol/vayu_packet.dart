import 'dart:typed_data';

import 'package:vayu/core/utils/crc32.dart';
import 'package:vayu/domain/protocol/packet_type.dart';

/// Standard binary wire frame for Vayu device-to-device communication.
///
/// Wire Format:
/// - Magic: 2 bytes (0x53, 0x53 -> 'SS')
/// - Protocol Version: 1 byte (0x01)
/// - Packet Type: 1 byte (PacketType code)
/// - Packet ID: 8 bytes (uint64 sequence / timestamp)
/// - Source Device ID: 16 bytes
/// - Destination Device ID: 16 bytes
/// - TTL / Hop Count: 1 byte (uint8)
/// - Payload Length: 4 bytes (uint32)
/// - Payload: N bytes
/// - CRC32 Checksum: 4 bytes (IEEE 802.3 over Header + Payload)
class VayuPacket {
  static const int magic1 = 0x53; // 'S'
  static const int magic2 = 0x53; // 'S'
  static const int currentProtocolVersion = 1;
  static const int headerSize = 49;
  static const int checksumSize = 4;
  static const int minPacketSize = headerSize + checksumSize; // 53 bytes

  final int version;
  final PacketType packetType;
  final int packetId;
  final Uint8List sourceDeviceId;
  final Uint8List destinationDeviceId;
  final int ttl;
  final Uint8List payload;

  VayuPacket({
    this.version = currentProtocolVersion,
    required this.packetType,
    required this.packetId,
    required this.sourceDeviceId,
    required this.destinationDeviceId,
    this.ttl = 3,
    required this.payload,
  }) {
    if (sourceDeviceId.length != 16) {
      throw ArgumentError.value(
        sourceDeviceId.length,
        'sourceDeviceId',
        'Source device ID must be exactly 16 bytes',
      );
    }
    if (destinationDeviceId.length != 16) {
      throw ArgumentError.value(
        destinationDeviceId.length,
        'destinationDeviceId',
        'Destination device ID must be exactly 16 bytes',
      );
    }
    if (ttl < 0 || ttl > 255) {
      throw ArgumentError.value(ttl, 'ttl', 'TTL must be between 0 and 255');
    }
  }

  /// Encodes this packet into a contiguous byte buffer including the CRC32 checksum.
  Uint8List toBytes() {
    final totalSize = headerSize + payload.length + checksumSize;
    final buffer = Uint8List(totalSize);
    final byteData = ByteData.sublistView(buffer);

    // Header
    byteData.setUint8(0, magic1);
    byteData.setUint8(1, magic2);
    byteData.setUint8(2, version);
    byteData.setUint8(3, packetType.code);
    byteData.setInt64(4, packetId, Endian.big);

    // Source (16B) & Destination (16B)
    buffer.setRange(12, 28, sourceDeviceId);
    buffer.setRange(28, 44, destinationDeviceId);

    // TTL & Payload Length
    byteData.setUint8(44, ttl);
    byteData.setUint32(45, payload.length, Endian.big);

    // Payload
    if (payload.isNotEmpty) {
      buffer.setRange(headerSize, headerSize + payload.length, payload);
    }

    // CRC32 over Header + Payload
    final checksum = Crc32.computeRange(buffer, 0, headerSize + payload.length);
    byteData.setUint32(totalSize - checksumSize, checksum, Endian.big);

    return buffer;
  }

  /// Deserializes a [VayuPacket] from raw [bytes] and validates header and CRC32 integrity.
  static VayuPacket fromBytes(Uint8List bytes) {
    if (bytes.length < minPacketSize) {
      throw FormatException(
        'Packet too short: received ${bytes.length} bytes, minimum expected is $minPacketSize',
      );
    }

    final byteData = ByteData.sublistView(bytes);

    // 1. Verify Magic
    final m1 = byteData.getUint8(0);
    final m2 = byteData.getUint8(1);
    if (m1 != magic1 || m2 != magic2) {
      throw FormatException(
        'Invalid packet magic: expected [0x${magic1.toRadixString(16)}, 0x${magic2.toRadixString(16)}], got [0x${m1.toRadixString(16)}, 0x${m2.toRadixString(16)}]',
      );
    }

    // 2. Protocol Version
    final version = byteData.getUint8(2);
    if (version != currentProtocolVersion) {
      throw FormatException('Unsupported protocol version: $version');
    }

    // 3. Packet Type
    final typeCode = byteData.getUint8(3);
    final packetType = PacketType.fromCode(typeCode);

    // 4. Packet ID
    final packetId = byteData.getInt64(4, Endian.big);

    // 5. Source and Destination IDs
    final sourceId = bytes.sublist(12, 28);
    final destId = bytes.sublist(28, 44);

    // 6. TTL & Payload Length
    final ttl = byteData.getUint8(44);
    final payloadLength = byteData.getUint32(45, Endian.big);

    final expectedTotalSize = headerSize + payloadLength + checksumSize;
    if (bytes.length < expectedTotalSize) {
      throw FormatException(
        'Incomplete packet: expected $expectedTotalSize bytes, got ${bytes.length}',
      );
    }

    // 7. Checksum validation
    final expectedChecksum = byteData.getUint32(
      expectedTotalSize - checksumSize,
      Endian.big,
    );
    final computedChecksum = Crc32.computeRange(
      bytes,
      0,
      headerSize + payloadLength,
    );
    if (computedChecksum != expectedChecksum) {
      throw FormatException(
        'CRC32 checksum mismatch: expected $expectedChecksum, computed $computedChecksum',
      );
    }

    // 8. Extract payload (one copy: [bytes] may be a reused framing buffer).
    final payload = bytes.sublist(headerSize, headerSize + payloadLength);

    return VayuPacket(
      version: version,
      packetType: packetType,
      packetId: packetId,
      sourceDeviceId: sourceId,
      destinationDeviceId: destId,
      ttl: ttl,
      payload: payload,
    );
  }

  /// Returns a copy of this packet with optional modified fields (e.g. decremented TTL for relay forwarding).
  VayuPacket copyWith({
    int? version,
    PacketType? packetType,
    int? packetId,
    Uint8List? sourceDeviceId,
    Uint8List? destinationDeviceId,
    int? ttl,
    Uint8List? payload,
  }) {
    return VayuPacket(
      version: version ?? this.version,
      packetType: packetType ?? this.packetType,
      packetId: packetId ?? this.packetId,
      sourceDeviceId: sourceDeviceId ?? this.sourceDeviceId,
      destinationDeviceId: destinationDeviceId ?? this.destinationDeviceId,
      ttl: ttl ?? this.ttl,
      payload: payload ?? this.payload,
    );
  }
}
