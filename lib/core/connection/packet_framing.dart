import 'dart:async';
import 'dart:typed_data';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';

/// StreamTransformer that reconstructs discrete [VayuPacket] frames
/// from an arbitrary, fragmented stream of incoming byte chunks (e.g. TCP socket).
class PacketStreamTransformer
    extends StreamTransformerBase<Uint8List, VayuPacket> {
  /// Maximum permitted payload size to prevent memory exhaustion attacks (16 MB).
  static const int maxPayloadLength = 16 * 1024 * 1024;

  /// Largest payload accepted before the peer has authenticated. Handshake
  /// packets are tiny; the margin covers a batch offer that the sender may
  /// send a moment before this side finishes authenticating it.
  static const int unauthenticatedMaxPayloadLength = 4 * 1024 * 1024;

  /// Current limit; [FramedTransportConnection] raises it once secured.
  final int Function() maxPayload;

  PacketStreamTransformer({int Function()? maxPayload})
    : maxPayload = maxPayload ?? (() => maxPayloadLength);

  @override
  Stream<VayuPacket> bind(Stream<Uint8List> stream) {
    return Stream<VayuPacket>.eventTransformed(
      stream,
      (sink) => _PacketSink(sink, maxPayload),
    );
  }
}

class _PacketSink implements EventSink<Uint8List> {
  final EventSink<VayuPacket> _outputSink;
  final int Function() _maxPayload;

  // Contiguous byte buffer with a read cursor. The previous List<int> stored one
  // boxed element per byte and shifted the whole remainder on every packet, which
  // made reassembly cost grow with the amount of data in flight.
  Uint8List _buffer = Uint8List(256 * 1024);
  int _start = 0;
  int _end = 0;

  _PacketSink(this._outputSink, this._maxPayload);

  int get _available => _end - _start;

  @override
  void add(Uint8List chunk) {
    _append(chunk);
    _processBuffer();
  }

  void _append(Uint8List chunk) {
    if (_end + chunk.length > _buffer.length) {
      final needed = _available + chunk.length;
      if (needed <= _buffer.length) {
        // Enough room once consumed bytes are dropped: compact in place.
        _buffer.setRange(0, _available, _buffer, _start);
      } else {
        var capacity = _buffer.length * 2;
        while (capacity < needed) {
          capacity *= 2;
        }
        final grown = Uint8List(capacity)
          ..setRange(0, _available, _buffer, _start);
        _buffer = grown;
      }
      _end = _available;
      _start = 0;
    }
    _buffer.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  void _consume(int count) {
    _start += count;
    if (_start == _end) {
      _start = 0;
      _end = 0;
    }
  }

  void _processBuffer() {
    while (_available >= VayuPacket.minPacketSize) {
      // 1. Locate magic bytes 0x53, 0x53
      int magicIndex = -1;
      for (int i = _start; i <= _end - 2; i++) {
        if (_buffer[i] == VayuPacket.magic1 &&
            _buffer[i + 1] == VayuPacket.magic2) {
          magicIndex = i - _start;
          break;
        }
      }

      if (magicIndex == -1) {
        // Keep only the last byte if it might be the first magic byte
        if (_buffer[_end - 1] == VayuPacket.magic1) {
          _consume(_available - 1);
        } else {
          _consume(_available);
        }
        return;
      }

      // Discard any garbage preceding the magic bytes
      if (magicIndex > 0) {
        _consume(magicIndex);
      }

      // Need at least header size (49 bytes) to inspect payload length
      if (_available < VayuPacket.headerSize) {
        return;
      }

      // 2. Read payload length at offset 45 (uint32 big-endian)
      final payloadLength = ByteData.sublistView(
        _buffer,
        _start + 45,
        _start + 49,
      ).getUint32(0, Endian.big);

      // Bounds check payload length
      if (payloadLength > _maxPayload()) {
        AppLogger.warning(
          'PacketFraming',
          'Payload length $payloadLength exceeds limit; dropping corrupt magic header',
        );
        _consume(1); // Discard 1 byte and re-scan
        continue;
      }

      final totalPacketSize =
          VayuPacket.headerSize + payloadLength + VayuPacket.checksumSize;

      // Wait until the full packet arrives
      if (_available < totalPacketSize) {
        return;
      }

      // 3. Copy out exact packet bytes; the buffer is reused for later data.
      final packetBytes = Uint8List.fromList(
        Uint8List.sublistView(_buffer, _start, _start + totalPacketSize),
      );

      // 4. Validate and emit packet
      try {
        final packet = VayuPacket.fromBytes(packetBytes);
        _consume(totalPacketSize);
        _outputSink.add(packet);
      } catch (e) {
        AppLogger.warning(
          'PacketFraming',
          'Dropped corrupted frame or false magic header: $e',
        );
        _consume(1); // Advance by 1 byte to find real magic header
      }
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _outputSink.addError(error, stackTrace);
  }

  @override
  void close() {
    _start = 0;
    _end = 0;
    _outputSink.close();
  }
}
