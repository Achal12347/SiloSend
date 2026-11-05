import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/capabilities/capability_coordinator.dart';
import 'package:vayu/core/lifecycle/app_lifecycle_manager.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';

const _off = SystemCapabilities(
  platformName: 'android',
  bluetoothState: RadioState.disabled,
  nearbyPermission: PermissionStatus.granted,
  lanState: NetworkState.disconnected,
);
const _on = SystemCapabilities(
  platformName: 'android',
  bluetoothState: RadioState.enabled,
  nearbyPermission: PermissionStatus.granted,
  lanState: NetworkState.disconnected,
);

class _Platform extends PlatformService {
  SystemCapabilities caps = _off;

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      DeviceCapabilities.unknown;

  @override
  Future<SystemCapabilities> checkCapabilities() async => caps;

  @override
  Future<bool> isBleSupported() async => true;

  @override
  Future<bool> isWifiDirectSupported() async => false;

  @override
  Future<bool> requestPermissions() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a change made during a refresh is not lost', () async {
    final platform = _Platform();
    final discoveryRestart = Completer<void>();
    var callbacks = 0;
    final lifecycle = AppLifecycleManager();
    final coordinator = CapabilityCoordinator(
      platformService: platform,
      lifecycleManager: lifecycle,
      onCapabilitiesChanged: () async {
        callbacks++;
        if (callbacks == 1) await discoveryRestart.future;
      },
    );
    addTearDown(coordinator.dispose);

    // The first refresh saw Bluetooth off and is restarting discovery.
    final first = coordinator.refresh();
    await pumpEventQueue();
    expect(callbacks, 1);

    // Bluetooth turned on meanwhile: this used to return the old state.
    platform.caps = _on;
    final second = coordinator.refresh();
    discoveryRestart.complete();

    expect((await second).canUseBle, isTrue);
    await first;
    expect(coordinator.state.canUseBle, isTrue);
    expect(callbacks, 2);
  });
}
