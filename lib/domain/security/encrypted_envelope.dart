import 'dart:typed_data';

/// Encapsulates an encrypted payload frame transferred inside a SiloSendPacket.
///
/// Binary Wire Layout:
/// - Epoch: 1 byte (uint8, 0..255)
/// - Sequence Number: 8 bytes (uint64, big-endian)
/// - Ciphertext: N bytes
/// - Authentication Tag: 16 bytes (AES-256-GCM tag)
///
/// Total Overhead: 25 bytes.
class EncryptedEnvelope {
  static const int headerOverhead = 9; // 1B epoch + 8B sequenceNumber
  static const int tagLength = 16; // 16B AES-GCM tag
  static const int minEnvelopeSize = headerOverhead + tagLength; // 25 bytes

  /// Key epoch counter for distinguishing keys during rekeying transitions.
  final int epoch;

  /// Monotonic sequence counter for replay protection and AEAD nonce construction.
  final int sequenceNumber;

  /// AES-256-GCM encrypted ciphertext bytes.
  final Uint8List ciphertext;

  /// 16-byte AES-256-GCM authentication tag.
  final Uint8List authTag;

  EncryptedEnvelope({
    required this.epoch,
    required this.sequenceNumber,
    required this.ciphertext,
    required this.authTag,
  }) {
    if (epoch < 0 || epoch > 255) {
      throw ArgumentError.value(
        epoch,
        'epoch',
        'Epoch must be between 0 and 255',
      );
    }
    if (sequenceNumber < 0) {
      throw ArgumentError.value(
        sequenceNumber,
        'sequenceNumber',
        'Sequence number cannot be negative',
      );
    }
    if (authTag.length != tagLength) {
      throw ArgumentError.value(
        authTag.length,
        'authTag',
        'Authentication tag must be exactly $tagLength bytes',
      );
    }
  }

  /// Serializes the envelope into a contiguous byte buffer.
  Uint8List toBytes() {
    final totalSize = headerOverhead + ciphertext.length + tagLength;
    final buffer = Uint8List(totalSize);
    final byteData = ByteData.sublistView(buffer);

    // Header
    byteData.setUint8(0, epoch);
    byteData.setUint64(1, sequenceNumber, Endian.big);

    // Ciphertext
    if (ciphertext.isNotEmpty) {
      buffer.setRange(
        headerOverhead,
        headerOverhead + ciphertext.length,
        ciphertext,
      );
    }

    // Auth Tag
    buffer.setRange(totalSize - tagLength, totalSize, authTag);

    return buffer;
  }

  /// Deserializes an [EncryptedEnvelope] from raw wire bytes.
  static EncryptedEnvelope fromBytes(Uint8List bytes) {
    if (bytes.length < minEnvelopeSize) {
      throw FormatException(
        'EncryptedEnvelope too short: received ${bytes.length} bytes, expected at least $minEnvelopeSize',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final epoch = byteData.getUint8(0);
    final sequenceNumber = byteData.getUint64(1, Endian.big);

    final ciphertextLength = bytes.length - minEnvelopeSize;
    final ciphertext = Uint8List.fromList(
      bytes.sublist(headerOverhead, headerOverhead + ciphertextLength),
    );
    final authTag = Uint8List.fromList(
      bytes.sublist(bytes.length - tagLength, bytes.length),
    );

    return EncryptedEnvelope(
      epoch: epoch,
      sequenceNumber: sequenceNumber,
      ciphertext: ciphertext,
      authTag: authTag,
    );
  }
}
