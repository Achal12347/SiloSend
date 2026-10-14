import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/system_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.achyrio.vayu/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'permission request waits for a slow user answer instead of timing out',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        // The user takes longer than the old 2 second limit to tap Allow.
        await Future<void>.delayed(const Duration(seconds: 3));
        return 'granted';
      });
      final service = SystemPlatformService(isAndroidOverride: true);
      expect(
        await service.requestNearbyPermissions(),
        PermissionStatus.granted,
      );
    },
  );

  test('concurrent permission requests share one native dialog', () async {
    var calls = 0;
    final answer = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) {
      calls++;
      return answer.future;
    });
    final service = SystemPlatformService(isAndroidOverride: true);
    final first = service.requestNearbyPermissions();
    final second = service.requestNearbyPermissions();
    answer.complete('granted');
    expect(await first, PermissionStatus.granted);
    expect(await second, PermissionStatus.granted);
    expect(calls, 1);
  });

  test('Bluetooth enable request waits for the user and dedupes', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      await Future<void>.delayed(const Duration(seconds: 3));
      return true;
    });
    final service = SystemPlatformService(isAndroidOverride: true);
    final results = await Future.wait([
      service.requestEnableBluetooth(),
      service.requestEnableBluetooth(),
    ]);
    expect(results, [true, true]);
    expect(calls, 1);
  });
}
