import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/transfer/transfer_speed_meter.dart';

void main() {
  final start = DateTime(2026, 11, 5);
  DateTime at(int ms) => start.add(Duration(milliseconds: ms));

  test('reports nothing until there is enough to measure', () {
    final meter = TransferSpeedMeter();
    expect(meter.update(0, at(0)), 0);
    expect(meter.update(1000, at(100)), 0);
  });

  test('bursts of chunks read as a steady speed', () {
    final meter = TransferSpeedMeter();
    const mib = 1024 * 1024;
    // 10 MiB/s arriving as 2 MiB bursts every 200 ms, with no bytes between.
    var speed = 0.0;
    for (var i = 0; i <= 50; i++) {
      final bytes = (i ~/ 2) * 2 * mib;
      speed = meter.update(bytes, at(i * 100));
      if (i > 30) {
        expect(speed, closeTo(10.0 * mib, 1.0 * mib));
      }
    }
  });

  test('follows a real change within the window', () {
    final meter = TransferSpeedMeter();
    const mib = 1024 * 1024;
    var bytes = 0;
    for (var i = 0; i <= 40; i++) {
      bytes += 2 * mib;
      meter.update(bytes, at(i * 100));
    }
    var speed = 0.0;
    for (var i = 41; i <= 90; i++) {
      bytes += mib ~/ 2;
      speed = meter.update(bytes, at(i * 100));
    }
    expect(speed, closeTo(5.0 * mib, 1.0 * mib));
  });
}
