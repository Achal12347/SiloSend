import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/security/replay_protection_filter.dart';

void main() {
  group('ReplayProtectionFilter Tests', () {
    late ReplayProtectionFilter filter;

    setUp(() {
      filter = ReplayProtectionFilter();
    });

    test('accepts first packet and initializes sliding window', () {
      expect(filter.isInitialized, isFalse);
      expect(filter.checkSequence(0), equals(ReplayDecision.acceptNewer));
      filter.commitSequence(0);
      expect(filter.isInitialized, isTrue);
      expect(filter.rxWindowMax, equals(0));
      expect(filter.rxBitmap, equals(1));
    });

    test('accepts strictly in-order sequence numbers', () {
      for (int i = 0; i < 100; i++) {
        expect(filter.checkSequence(i), equals(ReplayDecision.acceptNewer));
        filter.commitSequence(i);
        expect(filter.rxWindowMax, equals(i));
      }
    });

    test('accepts out-of-order packets within 64-packet window', () {
      filter.commitSequence(10); // Window: [0..10]
      expect(filter.rxWindowMax, equals(10));

      // Packet 8 is unseen inside window
      expect(filter.checkSequence(8), equals(ReplayDecision.acceptWindow));
      filter.commitSequence(8);

      // Packet 5 is unseen inside window
      expect(filter.checkSequence(5), equals(ReplayDecision.acceptWindow));
      filter.commitSequence(5);

      // Packet 15 is newer
      expect(filter.checkSequence(15), equals(ReplayDecision.acceptNewer));
      filter.commitSequence(15);
      expect(filter.rxWindowMax, equals(15));

      // Packet 8 is now duplicate
      expect(filter.checkSequence(8), equals(ReplayDecision.rejectDuplicate));

      // Packet 7 was unseen
      expect(filter.checkSequence(7), equals(ReplayDecision.acceptWindow));
      filter.commitSequence(7);
      expect(filter.checkSequence(7), equals(ReplayDecision.rejectDuplicate));
    });

    test('rejects duplicate sequence numbers', () {
      filter.commitSequence(5);
      expect(filter.checkSequence(5), equals(ReplayDecision.rejectDuplicate));

      filter.commitSequence(6);
      expect(filter.checkSequence(5), equals(ReplayDecision.rejectDuplicate));
      expect(filter.checkSequence(6), equals(ReplayDecision.rejectDuplicate));
    });

    test('rejects stale sequence numbers beyond 64-packet window', () {
      filter.commitSequence(100); // Window: [100 - 63, ..., 100] = [37 .. 100]

      expect(filter.checkSequence(37), equals(ReplayDecision.acceptWindow));
      expect(filter.checkSequence(36), equals(ReplayDecision.rejectStale));
      expect(filter.checkSequence(10), equals(ReplayDecision.rejectStale));
      expect(filter.checkSequence(0), equals(ReplayDecision.rejectStale));
    });

    test('large advance (>= 64) resets bitmap to 1 and moves max window', () {
      filter.commitSequence(10);
      filter.commitSequence(80); // Advance of 70 >= 64

      expect(filter.rxWindowMax, equals(80));
      expect(filter.rxBitmap, equals(1));

      // 10 is now stale
      expect(filter.checkSequence(10), equals(ReplayDecision.rejectStale));
      // 79 is inside window and unseen
      expect(filter.checkSequence(79), equals(ReplayDecision.acceptWindow));
    });

    test('checkSequence does not mutate filter state until committed', () {
      filter.commitSequence(10);

      // Repeated checks on unseen packet do not mark it as seen
      expect(filter.checkSequence(8), equals(ReplayDecision.acceptWindow));
      expect(filter.checkSequence(8), equals(ReplayDecision.acceptWindow));
      expect(filter.rxBitmap, equals(1)); // Only bit 0 set

      // Now commit
      filter.commitSequence(8);
      expect(filter.checkSequence(8), equals(ReplayDecision.rejectDuplicate));
    });

    test('reset clears all state', () {
      filter.commitSequence(50);
      filter.reset();
      expect(filter.isInitialized, isFalse);
      expect(filter.rxWindowMax, equals(0));
      expect(filter.rxBitmap, equals(0));
    });
  });
}
