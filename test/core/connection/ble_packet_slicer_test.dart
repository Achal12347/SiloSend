import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/connection/ble_packet_slicer.dart';

void main() {
  group('BlePacketSlicer ATT-MTU Slicing & Reassembly Tests', () {
    test('computes effective payload sizes with ATT header deduction and bounds clamping', () {
      // Default MTU 23 -> 20 bytes payload
      expect(BlePacketSlicer.computeEffectivePayload(23), 20);

      // Target MTU 512 -> 509 bytes payload
      expect(BlePacketSlicer.computeEffectivePayload(512), 509);

      // Typical MTU 247 -> 244 bytes payload
      expect(BlePacketSlicer.computeEffectivePayload(247), 244);

      // Below min MTU clamped to 20
      expect(BlePacketSlicer.computeEffectivePayload(15), 20);

      // Above max MTU clamped to 509
      expect(BlePacketSlicer.computeEffectivePayload(1000), 509);
    });

    test('slices buffers smaller than or equal to MTU without splitting', () {
      final data15 = Uint8List.fromList(List.generate(15, (i) => i));
      final slices15 = BlePacketSlicer.slice(data15, mtu: 23);
      expect(slices15.length, 1);
      expect(slices15.first, equals(data15));

      final data20 = Uint8List.fromList(List.generate(20, (i) => i));
      final slices20 = BlePacketSlicer.slice(data20, mtu: 23);
      expect(slices20.length, 1);
      expect(slices20.first, equals(data20));
    });

    test('slices buffers exceeding MTU into exact ATT-safe chunks', () {
      // 55 bytes with default MTU (20 bytes max): 20 + 20 + 15 = 3 chunks
      final data55 = Uint8List.fromList(List.generate(55, (i) => i));
      final slices = BlePacketSlicer.slice(data55, mtu: 23);

      expect(slices.length, 3);
      expect(slices[0].length, 20);
      expect(slices[1].length, 20);
      expect(slices[2].length, 15);

      // Verify content integrity
      final reassembled = BlePacketSlicer.reassemble(slices);
      expect(reassembled, equals(data55));
    });

    test(
      'slices large buffer using negotiated MTU 512 (509 bytes payload)',
      () {
        // 1200 bytes with MTU 512: 509 + 509 + 182 = 3 chunks
        final data1200 = Uint8List.fromList(
          List.generate(1200, (i) => i % 256),
        );
        final slices = BlePacketSlicer.slice(data1200, mtu: 512);

        expect(slices.length, 3);
        expect(slices[0].length, 509);
        expect(slices[1].length, 509);
        expect(slices[2].length, 182);

        final reassembled = BlePacketSlicer.reassemble(slices);
        expect(reassembled, equals(data1200));
      },
    );

    test('handles empty buffers gracefully', () {
      final empty = Uint8List(0);
      final slices = BlePacketSlicer.slice(empty);
      expect(slices.length, 1);
      expect(slices.first.isEmpty, isTrue);

      final reassembled = BlePacketSlicer.reassemble([]);
      expect(reassembled.isEmpty, isTrue);
    });
  });
}
