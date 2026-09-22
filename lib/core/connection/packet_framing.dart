import 'dart:async';
import 'dart:typed_data';

import 'package:silosend_datasharing_app/core/logging/app_logger.dart';
import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';

/// StreamTransformer that reconstructs discrete [SiloSendPacket] frames
/// from an arbitrary, fragmented stream of incoming byte chunks (e.g. TCP socket).
class PacketStreamTransformer
    extends StreamTransformerBase<Uint8List, SiloSendPacket> {
  /// Maximum permitted payload size to prevent memory exhaustion attacks (16 MB).
  static const int maxPayloadLength = 16 * 1024 * 1024;

  @override
  Stream<SiloSendPacket> bind(Stream<Uint8List> stream) {
    return Stream<SiloSendPacket>.eventTransformed(
      stream,
      (sink) => _PacketSink(sink),
    );
  }
}

class _PacketSink implements EventSink<Uint8List> {
  final EventSink<SiloSendPacket> _outputSink;
  final List<int> _buffer = [];

  _PacketSink(this._outputSink);

  @override
  void add(Uint8List chunk) {
    _buffer.addAll(chunk);
    _processBuffer();
  }

  void _processBuffer() {
    while (_buffer.length >= SiloSendPacket.minPacketSize) {
      // 1. Locate magic bytes 0x53, 0x53
      int magicIndex = -1;
      for (int i = 0; i <= _buffer.length - 2; i++) {
        if (_buffer[i] == SiloSendPacket.magic1 &&
            _buffer[i + 1] == SiloSendPacket.magic2) {
          magicIndex = i;
          break;
        }
      }

      if (magicIndex == -1) {
        // Keep only the last byte if it might be the first magic byte
        if (_buffer.isNotEmpty && _buffer.last == SiloSendPacket.magic1) {
          _buffer.removeRange(0, _buffer.length - 1);
        } else {
          _buffer.clear();
        }
        return;
      }

      // Discard any garbage preceding the magic bytes
      if (magicIndex > 0) {
        _buffer.removeRange(0, magicIndex);
      }

      // Need at least header size (49 bytes) to inspect payload length
      if (_buffer.length < SiloSendPacket.headerSize) {
        return;
      }

      // 2. Read payload length at offset 45 (uint32 big-endian)
      final byteData = ByteData.sublistView(
        Uint8List.fromList(_buffer.sublist(45, 49)),
      );
      final payloadLength = byteData.getUint32(0, Endian.big);

      // Bounds check payload length
      if (payloadLength > PacketStreamTransformer.maxPayloadLength) {
        AppLogger.warning(
          'PacketFraming',
          'Payload length $payloadLength exceeds limit; dropping corrupt magic header',
        );
        _buffer.removeRange(0, 1); // Discard 1 byte and re-scan
        continue;
      }

      final totalPacketSize =
          SiloSendPacket.headerSize +
          payloadLength +
          SiloSendPacket.checksumSize;

      // Wait until the full packet arrives
      if (_buffer.length < totalPacketSize) {
        return;
      }

      // 3. Extract exact packet bytes
      final packetBytes = Uint8List.fromList(
        _buffer.sublist(0, totalPacketSize),
      );

      // 4. Validate and emit packet
      try {
        final packet = SiloSendPacket.fromBytes(packetBytes);
        _buffer.removeRange(0, totalPacketSize);
        _outputSink.add(packet);
      } catch (e) {
        AppLogger.warning(
          'PacketFraming',
          'Dropped corrupted frame or false magic header: $e',
        );
        _buffer.removeRange(
          0,
          1,
        ); // Advance by 1 byte to find real magic header
      }
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _outputSink.addError(error, stackTrace);
  }

  @override
  void close() {
    _buffer.clear();
    _outputSink.close();
  }
}
