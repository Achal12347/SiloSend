import 'dart:typed_data';

/// Utility for slicing outgoing byte streams into ATT-MTU-safe chunks and reassembling them.
///
/// In Bluetooth Low Energy GATT communication:
/// - Standard default ATT MTU is 23 bytes (3 bytes ATT header + 20 bytes payload).
/// - Negotiated MTU (e.g. 512 or 247) allows larger payloads: `effectiveMtu = mtu - 3`.
/// - Writing or notifying a payload larger than `effectiveMtu` fails or drops bytes.
///
/// [BlePacketSlicer] ensures that every BLE transmission respects the negotiated ATT MTU.
class BlePacketSlicer {
  BlePacketSlicer._();

  static const int defaultAttMtu = 23;
  static const int targetAttMtu = 512;
  static const int attHeaderSize = 3;
  static const int minEffectivePayload = 20; // 23 - 3
  static const int maxEffectivePayload = 509; // 512 - 3

  /// Computes the maximum safe payload byte length for a given ATT [mtu].
  static int computeEffectivePayload(int mtu) {
    final effective = mtu - attHeaderSize;
    return effective.clamp(minEffectivePayload, maxEffectivePayload);
  }

  /// Slices [data] into contiguous chunks, each at most [effectiveMtu] bytes.
  static List<Uint8List> slice(Uint8List data, {int mtu = defaultAttMtu}) {
    if (data.isEmpty) {
      return [Uint8List(0)];
    }

    final maxChunkSize = computeEffectivePayload(mtu);
    if (data.length <= maxChunkSize) {
      return [Uint8List.fromList(data)];
    }

    final chunks = <Uint8List>[];
    int offset = 0;
    while (offset < data.length) {
      final chunkSize = (data.length - offset).clamp(0, maxChunkSize);
      chunks.add(Uint8List.fromList(data.sublist(offset, offset + chunkSize)));
      offset += chunkSize;
    }
    return chunks;
  }

  /// Reassembles an ordered list of [chunks] into a single contiguous byte buffer.
  static Uint8List reassemble(List<Uint8List> chunks) {
    if (chunks.isEmpty) {
      return Uint8List(0);
    }
    if (chunks.length == 1) {
      return chunks.first;
    }

    final totalLength = chunks.fold<int>(0, (sum, c) => sum + c.length);
    final result = Uint8List(totalLength);
    int offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }
}
