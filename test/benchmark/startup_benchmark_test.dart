import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

/// Startup time per step on this machine (Phase 18: measure first). A
/// desktop number is only a relative guide; phones report theirs in
/// Diagnostics ("Startup").
///
/// Run: VAYU_BENCH=1 flutter test test/benchmark/startup_benchmark_test.dart
void main() {
  final enabled = Platform.environment['VAYU_BENCH'] != null;

  test('startup steps', () async {
    final runs = <int>[];
    late Map<String, int> steps;
    for (var i = 0; i < 5; i++) {
      final app = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity.generate(
            displayName: 'Bench',
            platform: 'android',
          ),
        ),
      );
      await app.initialize();
      runs.add(app.startupTotalMs);
      steps = Map.of(app.startupSteps);
      app.dispose();
    }
    runs.sort();
    // ignore: avoid_print
    print('Startup ms over 5 runs: $runs (median ${runs[2]})');
    // ignore: avoid_print
    print('Last run by step: $steps');
  }, skip: enabled ? false : 'set VAYU_BENCH=1 to run');
}
