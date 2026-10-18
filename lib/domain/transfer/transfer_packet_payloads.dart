import 'dart:convert';
import 'dart:typed_data';

import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/utils/crc32.dart';

/// SACK / ACK operation types.
enum TransferAckType {
  offerAccepted(0x01),
  chunkReceived(0x02),
  transferCompleted(0x03),
  resumeCheckpoint(0x04);

  final int code;
  const TransferAckType(this.code);

  static TransferAckType fromCode(int code) {
    for (final type in TransferAckType.values) {
      if (type.code == code) return type;
    }
    throw FormatException(
      'Unknown TransferAckType code: 0x${code.toRadixString(16)}',
    );
  }
}

/// Reason codes for Negative Acknowledgments (NACK).
enum TransferNackReason {
  chunkCrcMismatch(0x01),
  outOfOrderWindowExceeded(0x02),
  storageFull(0x03),
  ioError(0x04);

  final int code;
  const TransferNackReason(this.code);

  static TransferNackReason fromCode(int code) {
    for (final reason in TransferNackReason.values) {
      if (reason.code == code) return reason;
    }
    throw FormatException(
      'Unknown TransferNackReason code: 0x${code.toRadixString(16)}',
    );
  }
}

/// Reason codes for transfer cancellation.
enum TransferCancelReason {
  userCancelled(0x01),
  timeout(0x02),
  declined(0x03),
  checksumMismatch(0x04),
  storageFull(0x05),
  connectionClosed(0x06),
  // The receiver could not write or promote the file for a reason other than space.
  ioError(0x07),
  // The sender could not read its own source file.
  sourceUnreadable(0x08),
  // The receiver is not on its Receive screen (and accepts nothing outside it).
  notReceiving(0x09);

  final int code;
  const TransferCancelReason(this.code);

  static TransferCancelReason fromCode(int code) {
    for (final reason in TransferCancelReason.values) {
      if (reason.code == code) return reason;
    }
    throw FormatException(
      'Unknown TransferCancelReason code: 0x${code.toRadixString(16)}',
    );
  }
}

/// Binary wire framing for Transfer Metadata announcement (0x10).
class TransferMetadataPayload {
  static const int minHeaderSize = 65; // 16 + 1 + 8 + 4 + 4 + 32
  static const int maxNameLength = 255;
  static const int maxMimeLength = 128;
  static const int maxExtraMetadataLength = 4096;

  final Uint8List transferId; // 16 bytes
  final PayloadType payloadType; // 1 byte
  final int totalBytes; // uint64
  final int chunkSize; // uint32
  final int chunkCount; // uint32
  final Uint8List sha256Hash; // 32 bytes
  final String fileName; // max 255 bytes UTF-8 (sanitized)
  final String mimeType; // max 128 bytes UTF-8
  final Uint8List? extraMetadata; // max 4096 bytes

  TransferMetadataPayload({
    required this.transferId,
    required this.payloadType,
    required this.totalBytes,
    required this.chunkSize,
    required this.chunkCount,
    required this.sha256Hash,
    required String fileName,
    required this.mimeType,
    this.extraMetadata,
  }) : fileName = sanitizeFileName(fileName) {
    if (transferId.length != 16) {
      throw ArgumentError.value(
        transferId.length,
        'transferId',
        'Must be exactly 16 bytes',
      );
    }
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'Cannot be negative');
    }
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be positive');
    }
    final expectedChunkCount = totalBytes == 0
        ? 0
        : (totalBytes + chunkSize - 1) ~/ chunkSize;
    if (chunkCount != expectedChunkCount) {
      throw ArgumentError(
        'Metadata consistency error: chunkCount ($chunkCount) does not match '
        'expected ($expectedChunkCount) for totalBytes=$totalBytes, chunkSize=$chunkSize',
      );
    }
    if (sha256Hash.length != 32) {
      throw ArgumentError.value(
        sha256Hash.length,
        'sha256Hash',
        'Must be exactly 32 bytes',
      );
    }
    if (utf8.encode(this.fileName).length > maxNameLength) {
      throw ArgumentError(
        'fileName exceeds maximum UTF-8 size of $maxNameLength bytes',
      );
    }
    if (utf8.encode(mimeType).length > maxMimeLength) {
      throw ArgumentError(
        'mimeType exceeds maximum UTF-8 size of $maxMimeLength bytes',
      );
    }
    if (extraMetadata != null &&
        extraMetadata!.length > maxExtraMetadataLength) {
      throw ArgumentError(
        'extraMetadata exceeds maximum size of $maxExtraMetadataLength bytes',
      );
    }
  }

  /// Sanitizes display filename: strips path traversal patterns, directory separators, and control characters.
  static String sanitizeFileName(String name) {
    var clean = name.replaceAll('\\', '/');
    if (clean.contains('/')) {
      clean = clean.split('/').last;
    }
    clean = clean.replaceAll(RegExp(r'\.\.+'), '.');
    clean = clean.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    if (clean.isEmpty) {
      clean = 'vayu_file.bin';
    }
    final encoded = utf8.encode(clean);
    if (encoded.length > maxNameLength) {
      clean = utf8.decode(
        encoded.sublist(0, maxNameLength),
        allowMalformed: true,
      );
    }
    return clean;
  }

  String get transferIdHex =>
      transferId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get sha256Hex =>
      sha256Hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List toBytes() {
    final nameBytes = Uint8List.fromList(utf8.encode(fileName));
    final mimeBytes = Uint8List.fromList(utf8.encode(mimeType));
    final extra = extraMetadata ?? Uint8List(0);

    final totalSize =
        minHeaderSize +
        2 +
        nameBytes.length +
        2 +
        mimeBytes.length +
        2 +
        extra.length;
    final buffer = Uint8List(totalSize);
    final byteData = ByteData.sublistView(buffer);

    // 1. Header (65 bytes)
    buffer.setRange(0, 16, transferId);
    buffer[16] = payloadType.code;
    byteData.setUint64(17, totalBytes, Endian.big);
    byteData.setUint32(25, chunkSize, Endian.big);
    byteData.setUint32(29, chunkCount, Endian.big);
    buffer.setRange(33, 65, sha256Hash);

    // 2. Length-prefixed fileName
    int offset = 65;
    byteData.setUint16(offset, nameBytes.length, Endian.big);
    offset += 2;
    buffer.setRange(offset, offset + nameBytes.length, nameBytes);
    offset += nameBytes.length;

    // 3. Length-prefixed mimeType
    byteData.setUint16(offset, mimeBytes.length, Endian.big);
    offset += 2;
    buffer.setRange(offset, offset + mimeBytes.length, mimeBytes);
    offset += mimeBytes.length;

    // 4. Length-prefixed extraMetadata
    byteData.setUint16(offset, extra.length, Endian.big);
    offset += 2;
    if (extra.isNotEmpty) {
      buffer.setRange(offset, offset + extra.length, extra);
    }

    return buffer;
  }

  factory TransferMetadataPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < minHeaderSize + 6) {
      throw FormatException(
        'Malformed TransferMetadataPayload: buffer too short (${bytes.length} bytes)',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final transferId = Uint8List.fromList(bytes.sublist(0, 16));
    final payloadType = PayloadType.fromCode(bytes[16]);
    final totalBytes = byteData.getUint64(17, Endian.big);
    final chunkSize = byteData.getUint32(25, Endian.big);
    final chunkCount = byteData.getUint32(29, Endian.big);
    final sha256Hash = Uint8List.fromList(bytes.sublist(33, 65));

    int offset = 65;
    if (offset + 2 > bytes.length) {
      throw const FormatException('Truncated fileName length');
    }
    final nameLen = byteData.getUint16(offset, Endian.big);
    offset += 2;
    if (nameLen > maxNameLength || offset + nameLen > bytes.length) {
      throw FormatException('Invalid fileName length ($nameLen bytes)');
    }
    final fileName = utf8.decode(bytes.sublist(offset, offset + nameLen));
    offset += nameLen;

    if (offset + 2 > bytes.length) {
      throw const FormatException('Truncated mimeType length');
    }
    final mimeLen = byteData.getUint16(offset, Endian.big);
    offset += 2;
    if (mimeLen > maxMimeLength || offset + mimeLen > bytes.length) {
      throw FormatException('Invalid mimeType length ($mimeLen bytes)');
    }
    final mimeType = utf8.decode(bytes.sublist(offset, offset + mimeLen));
    offset += mimeLen;

    if (offset + 2 > bytes.length) {
      throw const FormatException('Truncated extraMetadata length');
    }
    final extraLen = byteData.getUint16(offset, Endian.big);
    offset += 2;
    if (extraLen > maxExtraMetadataLength || offset + extraLen > bytes.length) {
      throw FormatException('Invalid extraMetadata length ($extraLen bytes)');
    }
    final extraMetadata = extraLen > 0
        ? Uint8List.fromList(bytes.sublist(offset, offset + extraLen))
        : null;

    return TransferMetadataPayload(
      transferId: transferId,
      payloadType: payloadType,
      totalBytes: totalBytes,
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      sha256Hash: sha256Hash,
      fileName: fileName,
      mimeType: mimeType,
      extraMetadata: extraMetadata,
    );
  }
}

/// Binary wire framing for individual transfer chunks (0x11).
class TransferChunkPayload {
  static const int headerSize = 36; // 16 + 4 + 8 + 4 + 4

  final Uint8List transferId; // 16 bytes
  final int chunkIndex; // uint32
  final int chunkOffset; // uint64
  final int chunkLength; // uint32
  final int chunkCrc32; // uint32
  final Uint8List chunkData; // chunkLength bytes

  TransferChunkPayload({
    required this.transferId,
    required this.chunkIndex,
    required this.chunkOffset,
    required this.chunkLength,
    required this.chunkCrc32,
    required this.chunkData,
  }) {
    if (transferId.length != 16) {
      throw ArgumentError.value(
        transferId.length,
        'transferId',
        'Must be exactly 16 bytes',
      );
    }
    if (chunkIndex < 0) {
      throw ArgumentError.value(chunkIndex, 'chunkIndex', 'Cannot be negative');
    }
    if (chunkOffset < 0) {
      throw ArgumentError.value(
        chunkOffset,
        'chunkOffset',
        'Cannot be negative',
      );
    }
    if (chunkLength != chunkData.length) {
      throw ArgumentError(
        'chunkLength ($chunkLength) does not match chunkData length (${chunkData.length})',
      );
    }
  }

  /// Factory that automatically computes the IEEE 802.3 CRC32 checksum over [chunkData].
  factory TransferChunkPayload.create({
    required Uint8List transferId,
    required int chunkIndex,
    required int chunkOffset,
    required Uint8List chunkData,
  }) {
    final crc = Crc32.compute(chunkData);
    return TransferChunkPayload(
      transferId: transferId,
      chunkIndex: chunkIndex,
      chunkOffset: chunkOffset,
      chunkLength: chunkData.length,
      chunkCrc32: crc,
      chunkData: chunkData,
    );
  }

  /// Verifies whether the chunk's internal CRC32 checksum matches the actual chunk data.
  bool verifyCrc() {
    return Crc32.compute(chunkData) == chunkCrc32;
  }

  Uint8List toBytes() {
    final buffer = Uint8List(headerSize + chunkData.length);
    final byteData = ByteData.sublistView(buffer);

    buffer.setRange(0, 16, transferId);
    byteData.setUint32(16, chunkIndex, Endian.big);
    byteData.setUint64(20, chunkOffset, Endian.big);
    byteData.setUint32(28, chunkLength, Endian.big);
    byteData.setUint32(32, chunkCrc32, Endian.big);

    if (chunkData.isNotEmpty) {
      buffer.setRange(headerSize, headerSize + chunkData.length, chunkData);
    }

    return buffer;
  }

  factory TransferChunkPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < headerSize) {
      throw FormatException(
        'Malformed TransferChunkPayload: buffer shorter than header (${bytes.length} < $headerSize)',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final transferId = bytes.sublist(0, 16);
    final chunkIndex = byteData.getUint32(16, Endian.big);
    final chunkOffset = byteData.getUint64(20, Endian.big);
    final chunkLength = byteData.getUint32(28, Endian.big);
    final chunkCrc32 = byteData.getUint32(32, Endian.big);

    if (bytes.length != headerSize + chunkLength) {
      throw FormatException(
        'Malformed TransferChunkPayload: expected ${headerSize + chunkLength} bytes, got ${bytes.length}',
      );
    }

    // A view, not a copy: [bytes] is the freshly decrypted packet payload,
    // owned by this chunk alone.
    final chunkData = Uint8List.sublistView(
      bytes,
      headerSize,
      headerSize + chunkLength,
    );

    return TransferChunkPayload(
      transferId: transferId,
      chunkIndex: chunkIndex,
      chunkOffset: chunkOffset,
      chunkLength: chunkLength,
      chunkCrc32: chunkCrc32,
      chunkData: chunkData,
    );
  }
}

/// Binary wire framing for Cumulative and Selective Acknowledgments (0x12).
class TransferAckPayload {
  static const int minHeaderSize = 35; // 16 + 1 + 4 + 8 + 4 + 2
  static const int maxSelectiveBitmapBytes = 32; // 256 chunks lookahead
  static const int noneAcked = 0xFFFFFFFF;

  final Uint8List transferId; // 16 bytes
  final TransferAckType ackType; // 1 byte
  final int
  highestContiguousChunkIndex; // uint32 (noneAcked = 0xFFFFFFFF if none yet)
  final int bytesReceived; // uint64
  final int selectiveBitmapOffset; // uint32
  final Uint8List selectiveBitmap; // max 32 bytes

  TransferAckPayload({
    required this.transferId,
    required this.ackType,
    required this.highestContiguousChunkIndex,
    required this.bytesReceived,
    required this.selectiveBitmapOffset,
    required this.selectiveBitmap,
  }) {
    if (transferId.length != 16) {
      throw ArgumentError.value(
        transferId.length,
        'transferId',
        'Must be exactly 16 bytes',
      );
    }
    if (bytesReceived < 0) {
      throw ArgumentError.value(
        bytesReceived,
        'bytesReceived',
        'Cannot be negative',
      );
    }
    if (selectiveBitmap.length > maxSelectiveBitmapBytes) {
      throw ArgumentError(
        'selectiveBitmap exceeds maximum length of $maxSelectiveBitmapBytes bytes',
      );
    }
  }

  /// Convenience factory for cumulative-only acknowledgment.
  factory TransferAckPayload.cumulative({
    required Uint8List transferId,
    required TransferAckType ackType,
    required int highestContiguousChunkIndex,
    required int bytesReceived,
  }) {
    return TransferAckPayload(
      transferId: transferId,
      ackType: ackType,
      highestContiguousChunkIndex: highestContiguousChunkIndex,
      bytesReceived: bytesReceived,
      selectiveBitmapOffset: highestContiguousChunkIndex == noneAcked
          ? 0
          : highestContiguousChunkIndex + 1,
      selectiveBitmap: Uint8List(0),
    );
  }

  /// Checks if a specific chunk index is acknowledged either contiguously or selectively.
  bool isChunkAcknowledged(int index) {
    if (highestContiguousChunkIndex != noneAcked &&
        index <= highestContiguousChunkIndex) {
      return true;
    }
    if (selectiveBitmap.isEmpty) return false;
    final diff = index - selectiveBitmapOffset;
    if (diff < 0 || diff >= selectiveBitmap.length * 8) return false;
    final byteIdx = diff ~/ 8;
    final bitIdx = diff % 8;
    return (selectiveBitmap[byteIdx] & (1 << bitIdx)) != 0;
  }

  Uint8List toBytes() {
    final buffer = Uint8List(minHeaderSize + selectiveBitmap.length);
    final byteData = ByteData.sublistView(buffer);

    buffer.setRange(0, 16, transferId);
    buffer[16] = ackType.code;
    byteData.setUint32(17, highestContiguousChunkIndex, Endian.big);
    byteData.setUint64(21, bytesReceived, Endian.big);
    byteData.setUint32(29, selectiveBitmapOffset, Endian.big);
    byteData.setUint16(33, selectiveBitmap.length, Endian.big);

    if (selectiveBitmap.isNotEmpty) {
      buffer.setRange(
        minHeaderSize,
        minHeaderSize + selectiveBitmap.length,
        selectiveBitmap,
      );
    }

    return buffer;
  }

  factory TransferAckPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < minHeaderSize) {
      throw FormatException(
        'Malformed TransferAckPayload: buffer too short (${bytes.length} bytes)',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final transferId = Uint8List.fromList(bytes.sublist(0, 16));
    final ackType = TransferAckType.fromCode(bytes[16]);
    final highestContiguousChunkIndex = byteData.getUint32(17, Endian.big);
    final bytesReceived = byteData.getUint64(21, Endian.big);
    final selectiveBitmapOffset = byteData.getUint32(29, Endian.big);
    final bitmapLen = byteData.getUint16(33, Endian.big);

    if (bitmapLen > maxSelectiveBitmapBytes ||
        bytes.length != minHeaderSize + bitmapLen) {
      throw FormatException(
        'Malformed TransferAckPayload: invalid bitmap length ($bitmapLen bytes)',
      );
    }

    final selectiveBitmap = bitmapLen > 0
        ? Uint8List.fromList(
            bytes.sublist(minHeaderSize, minHeaderSize + bitmapLen),
          )
        : Uint8List(0);

    return TransferAckPayload(
      transferId: transferId,
      ackType: ackType,
      highestContiguousChunkIndex: highestContiguousChunkIndex,
      bytesReceived: bytesReceived,
      selectiveBitmapOffset: selectiveBitmapOffset,
      selectiveBitmap: selectiveBitmap,
    );
  }
}

/// Binary wire framing for Negative Acknowledgments (0x13).
class TransferNackPayload {
  static const int minHeaderSize = 23; // 16 + 4 + 1 + 2
  static const int maxDetailsLength = 256;

  final Uint8List transferId; // 16 bytes
  final int chunkIndex; // uint32
  final TransferNackReason reason; // 1 byte
  final String details; // max 256 bytes UTF-8

  TransferNackPayload({
    required this.transferId,
    required this.chunkIndex,
    required this.reason,
    this.details = '',
  }) {
    if (transferId.length != 16) {
      throw ArgumentError.value(
        transferId.length,
        'transferId',
        'Must be exactly 16 bytes',
      );
    }
    if (chunkIndex < 0) {
      throw ArgumentError.value(chunkIndex, 'chunkIndex', 'Cannot be negative');
    }
    if (utf8.encode(details).length > maxDetailsLength) {
      throw ArgumentError(
        'details exceeds maximum UTF-8 size of $maxDetailsLength bytes',
      );
    }
  }

  Uint8List toBytes() {
    final detailBytes = Uint8List.fromList(utf8.encode(details));
    final buffer = Uint8List(minHeaderSize + detailBytes.length);
    final byteData = ByteData.sublistView(buffer);

    buffer.setRange(0, 16, transferId);
    byteData.setUint32(16, chunkIndex, Endian.big);
    buffer[20] = reason.code;
    byteData.setUint16(21, detailBytes.length, Endian.big);

    if (detailBytes.isNotEmpty) {
      buffer.setRange(
        minHeaderSize,
        minHeaderSize + detailBytes.length,
        detailBytes,
      );
    }

    return buffer;
  }

  factory TransferNackPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < minHeaderSize) {
      throw FormatException(
        'Malformed TransferNackPayload: buffer too short (${bytes.length} bytes)',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final transferId = Uint8List.fromList(bytes.sublist(0, 16));
    final chunkIndex = byteData.getUint32(16, Endian.big);
    final reason = TransferNackReason.fromCode(bytes[20]);
    final detailsLen = byteData.getUint16(21, Endian.big);

    if (detailsLen > maxDetailsLength ||
        bytes.length != minHeaderSize + detailsLen) {
      throw FormatException(
        'Malformed TransferNackPayload: invalid details length ($detailsLen bytes)',
      );
    }

    final details = detailsLen > 0
        ? utf8.decode(bytes.sublist(minHeaderSize, minHeaderSize + detailsLen))
        : '';

    return TransferNackPayload(
      transferId: transferId,
      chunkIndex: chunkIndex,
      reason: reason,
      details: details,
    );
  }
}

/// Binary wire framing for Transfer Cancellation (0x14).
class TransferCancelPayload {
  static const int minHeaderSize = 19; // 16 + 1 + 2
  static const int maxMessageLength = 512;

  final Uint8List transferId; // 16 bytes
  final TransferCancelReason reason; // 1 byte
  final String message; // max 512 bytes UTF-8

  TransferCancelPayload({
    required this.transferId,
    required this.reason,
    this.message = '',
  }) {
    if (transferId.length != 16) {
      throw ArgumentError.value(
        transferId.length,
        'transferId',
        'Must be exactly 16 bytes',
      );
    }
    if (utf8.encode(message).length > maxMessageLength) {
      throw ArgumentError(
        'message exceeds maximum UTF-8 size of $maxMessageLength bytes',
      );
    }
  }

  Uint8List toBytes() {
    final msgBytes = Uint8List.fromList(utf8.encode(message));
    final buffer = Uint8List(minHeaderSize + msgBytes.length);
    final byteData = ByteData.sublistView(buffer);

    buffer.setRange(0, 16, transferId);
    buffer[16] = reason.code;
    byteData.setUint16(17, msgBytes.length, Endian.big);

    if (msgBytes.isNotEmpty) {
      buffer.setRange(minHeaderSize, minHeaderSize + msgBytes.length, msgBytes);
    }

    return buffer;
  }

  factory TransferCancelPayload.fromBytes(Uint8List bytes) {
    if (bytes.length < minHeaderSize) {
      throw FormatException(
        'Malformed TransferCancelPayload: buffer too short (${bytes.length} bytes)',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final transferId = Uint8List.fromList(bytes.sublist(0, 16));
    final reason = TransferCancelReason.fromCode(bytes[16]);
    final msgLen = byteData.getUint16(17, Endian.big);

    if (msgLen > maxMessageLength || bytes.length != minHeaderSize + msgLen) {
      throw FormatException(
        'Malformed TransferCancelPayload: invalid message length ($msgLen bytes)',
      );
    }

    final message = msgLen > 0
        ? utf8.decode(bytes.sublist(minHeaderSize, minHeaderSize + msgLen))
        : '';

    return TransferCancelPayload(
      transferId: transferId,
      reason: reason,
      message: message,
    );
  }
}

/// Packet 0x17: the SHA-256 of a file whose offer was sent before the sender
/// finished hashing it (`late-hash-v1`). Layout: transferId (16) + digest (32).
class TransferDigestPayload {
  static const int size = 48;

  final Uint8List transferId;
  final Uint8List sha256Hash;

  TransferDigestPayload({required this.transferId, required this.sha256Hash}) {
    if (transferId.length != 16) {
      throw ArgumentError.value(
        transferId.length,
        'transferId',
        'Must be 16 bytes',
      );
    }
    if (sha256Hash.length != 32) {
      throw ArgumentError.value(
        sha256Hash.length,
        'sha256Hash',
        'Must be 32 bytes',
      );
    }
  }

  String get transferIdHex =>
      transferId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get sha256Hex =>
      sha256Hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List toBytes() => Uint8List(size)
    ..setRange(0, 16, transferId)
    ..setRange(16, size, sha256Hash);

  factory TransferDigestPayload.fromBytes(Uint8List bytes) {
    if (bytes.length != size) {
      throw FormatException('Invalid digest payload length (${bytes.length})');
    }
    return TransferDigestPayload(
      transferId: Uint8List.fromList(bytes.sublist(0, 16)),
      sha256Hash: Uint8List.fromList(bytes.sublist(16, size)),
    );
  }
}
