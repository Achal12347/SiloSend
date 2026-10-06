import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vayu/core/identity/device_identity_manager.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/lifecycle/app_lifecycle_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/system_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppContainer Tests', () {
    late Directory tempDir;
    late File storageFile;
    late FileIdentityStorage storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'vayu_container_test_',
      );
      storageFile = File('${tempDir.path}/identity.json');
      storage = FileIdentityStorage(storageFile);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'initializes and mints fresh persistent identity on first startup',
      () async {
        final container = AppContainer.standard(storage: storage);
        expect(container.isInitialized, isFalse);
        expect(container.identity, isNull);

        await container.initialize();

        expect(container.isInitialized, isTrue);
        expect(container.identity, isNotNull);
        expect(container.identity!.displayName, startsWith('Vayu-'));
        expect(container.identity!.idHex.length, equals(32));
        expect(container.capabilities.ble, equals(CapabilityStatus.unknown));
        expect(container.lifecycleState, equals(AppLifecycleState.resumed));

        // Verify file was written to disk
        expect(await storageFile.exists(), isTrue);

        container.dispose();
      },
    );

    test(
      'reloads existing identity on subsequent startup without re-minting',
      () async {
        // 1. First boot
        final container1 = AppContainer.standard(storage: storage);
        await container1.initialize();
        final firstId = container1.identity!.idHex;
        final firstName = container1.identity!.displayName;
        container1.dispose();

        // 2. Second boot with new container instance pointing to same storage
        final container2 = AppContainer.standard(storage: storage);
        await container2.initialize();

        expect(container2.identity!.idHex, equals(firstId));
        expect(container2.identity!.displayName, equals(firstName));

        container2.dispose();
      },
    );

    test('propagates identity display name changes reactively', () async {
      final container = AppContainer.standard(storage: storage);
      await container.initialize();

      final emittedNames = <String>[];
      final sub = container.identityStream.listen(
        (id) => emittedNames.add(id.displayName),
      );

      await container.identityManager.updateDisplayName('Achal Laptop');

      expect(container.identity!.displayName, equals('Achal Laptop'));
      await pumpEventQueue();
      expect(emittedNames, contains('Achal Laptop'));

      await sub.cancel();
      container.dispose();
    });

    test('propagates lifecycle state transitions reactively', () async {
      final lifecycleManager = AppLifecycleManager();
      final container = AppContainer(
        identityStorage: storage,
        identityManager: DeviceIdentityManager(storage),
        platformService: SystemPlatformService(),
        lifecycleManager: lifecycleManager,
      );

      await container.initialize();

      final states = <AppLifecycleState>[];
      final sub = container.lifecycleStream.listen(states.add);

      lifecycleManager.transitionTo(AppLifecycleState.paused);

      expect(container.lifecycleState, equals(AppLifecycleState.paused));
      await pumpEventQueue();
      expect(states, contains(AppLifecycleState.paused));

      await sub.cancel();
      container.dispose();
    });

    test(
      'initializes CapabilityCoordinator and reconciles capabilities on resume',
      () async {
        final mockPlatform = _MockAppContainerPlatform();
        final lifecycleManager = AppLifecycleManager();
        final container = AppContainer(
          identityStorage: storage,
          identityManager: DeviceIdentityManager(storage),
          platformService: mockPlatform,
          lifecycleManager: lifecycleManager,
        );

        await container.initialize();

        expect(container.capabilityCoordinator, isNotNull);
        expect(container.capabilityCoordinator.state.canUseLan, isTrue);
        expect(container.capabilityCoordinator.state.canUseBle, isFalse);

        // Change platform capabilities (e.g., user granted permissions in Settings and enabled Bluetooth)
        mockPlatform.caps = mockPlatform.caps.copyWith(
          bluetoothState: RadioState.enabled,
          nearbyPermission: PermissionStatus.granted,
        );

        // Transition paused -> resumed
        lifecycleManager.transitionTo(AppLifecycleState.paused);
        lifecycleManager.transitionTo(AppLifecycleState.resumed);
        await pumpEventQueue();

        expect(container.capabilityCoordinator.state.canUseBle, isTrue);
        expect(container.systemCapabilities.canUseBle, isTrue);

        container.dispose();
      },
    );
  });
}

class _MockAppContainerPlatform extends SystemPlatformService {
  SystemCapabilities caps = const SystemCapabilities(
    wifiEnabled: true,
    lanState: NetworkState.lanAvailable,
    bluetoothState: RadioState.disabled,
    nearbyPermission: PermissionStatus.denied,
    platformName: 'android',
  );

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: false,
        supportsNfc: false,
        hasCamera: false,
      );

  @override
  Future<SystemCapabilities> checkCapabilities() async => caps;
}
