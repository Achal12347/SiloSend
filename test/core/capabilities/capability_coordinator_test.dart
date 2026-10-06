import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/capabilities/capability_coordinator.dart';
import 'package:silosend_datasharing_app/core/lifecycle/app_lifecycle_manager.dart';
import 'package:silosend_datasharing_app/domain/identity/device_capabilities.dart';
import 'package:silosend_datasharing_app/domain/identity/system_capabilities.dart';
import 'package:silosend_datasharing_app/platform/platform_service.dart';

class _MockTestPlatformService extends PlatformService {
  SystemCapabilities currentCaps;
  bool appSettingsOpened = false;
  bool wifiSettingsOpened = false;
  bool bluetoothEnabledRequested = false;
  bool nearbyPermissionRequested = false;

  _MockTestPlatformService(this.currentCaps);

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
  Future<SystemCapabilities> checkCapabilities() async => currentCaps;

  @override
  Future<bool> isBleSupported() async => currentCaps.bluetoothState.isEnabled;

  @override
  Future<bool> isWifiDirectSupported() async => false;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<PermissionStatus> requestNearbyPermissions() async {
    nearbyPermissionRequested = true;
    currentCaps = currentCaps.copyWith(
      nearbyPermission: PermissionStatus.granted,
    );
    return PermissionStatus.granted;
  }

  @override
  Future<bool> requestEnableBluetooth() async {
    bluetoothEnabledRequested = true;
    currentCaps = currentCaps.copyWith(bluetoothState: RadioState.enabled);
    return true;
  }

  @override
  Future<void> openAppSettings() async {
    appSettingsOpened = true;
  }

  @override
  Future<void> openWifiSettings() async {
    wifiSettingsOpened = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CapabilityCoordinator Tests', () {
    late AppLifecycleManager lifecycleManager;

    setUp(() {
      lifecycleManager = AppLifecycleManager();
    });

    tearDown(() {
      lifecycleManager.dispose();
    });

    test(
      'recommends requestNearbyPermission when permission not requested yet',
      () async {
        final platform = _MockTestPlatformService(
          const SystemCapabilities(
            platformName: 'android',
            bluetoothState: RadioState.enabled,
            nearbyPermission: PermissionStatus.notRequested,
            lanState: NetworkState.lanAvailable,
          ),
        );

        final coordinator = CapabilityCoordinator(
          platformService: platform,
          lifecycleManager: lifecycleManager,
          initialCapabilities: platform.currentCaps,
        );

        expect(coordinator.state.canUseLan, isTrue);
        expect(coordinator.state.canUseBle, isFalse);
        expect(
          coordinator.state.operationalStatus,
          equals(CapabilityOperationalStatus.readyLanOnly),
        );
        expect(
          coordinator.state.recommendedAction,
          equals(CapabilityActionType.requestNearbyPermission),
        );
        expect(
          coordinator.state.actionButtonLabel,
          equals('Allow Nearby Access'),
        );

        // Executing recommended action requests permission directly
        final result = await coordinator.requestNearbyAccess();
        expect(result, equals(PermissionStatus.granted));
        expect(platform.nearbyPermissionRequested, isTrue);
        expect(coordinator.state.canUseBle, isTrue);
        expect(
          coordinator.state.operationalStatus,
          equals(CapabilityOperationalStatus.readyBoth),
        );
        expect(
          coordinator.state.recommendedAction,
          equals(CapabilityActionType.none),
        );

        coordinator.dispose();
      },
    );

    test('recommends enableBluetooth when bluetooth is off', () async {
      final platform = _MockTestPlatformService(
        const SystemCapabilities(
          platformName: 'android',
          bluetoothState: RadioState.disabled,
          nearbyPermission: PermissionStatus.granted,
          lanState: NetworkState.lanAvailable,
        ),
      );

      final coordinator = CapabilityCoordinator(
        platformService: platform,
        lifecycleManager: lifecycleManager,
        initialCapabilities: platform.currentCaps,
      );

      expect(
        coordinator.state.recommendedAction,
        equals(CapabilityActionType.enableBluetooth),
      );
      expect(coordinator.state.actionButtonLabel, equals('Turn On Bluetooth'));

      await coordinator.enableBluetooth();
      expect(platform.bluetoothEnabledRequested, isTrue);
      expect(coordinator.state.canUseBle, isTrue);
      expect(
        coordinator.state.recommendedAction,
        equals(CapabilityActionType.none),
      );

      coordinator.dispose();
    });

    test(
      'recommends openAppSettings when permission is permanently denied',
      () async {
        final platform = _MockTestPlatformService(
          const SystemCapabilities(
            platformName: 'android',
            bluetoothState: RadioState.enabled,
            nearbyPermission: PermissionStatus.permanentlyDenied,
            lanState: NetworkState.lanAvailable,
          ),
        );

        final coordinator = CapabilityCoordinator(
          platformService: platform,
          lifecycleManager: lifecycleManager,
          initialCapabilities: platform.currentCaps,
        );

        expect(
          coordinator.state.recommendedAction,
          equals(CapabilityActionType.openAppSettings),
        );
        expect(coordinator.state.actionButtonLabel, equals('Open Settings'));

        await coordinator.openAppSettings();
        expect(platform.appSettingsOpened, isTrue);

        coordinator.dispose();
      },
    );

    test(
      'continueWithLanOnly suppresses BLE action while keeping LAN active',
      () async {
        final platform = _MockTestPlatformService(
          const SystemCapabilities(
            platformName: 'android',
            bluetoothState: RadioState.disabled,
            nearbyPermission: PermissionStatus.notRequested,
            lanState: NetworkState.lanAvailable,
          ),
        );

        final coordinator = CapabilityCoordinator(
          platformService: platform,
          lifecycleManager: lifecycleManager,
          initialCapabilities: platform.currentCaps,
        );

        expect(
          coordinator.state.recommendedAction,
          equals(CapabilityActionType.requestNearbyPermission),
        );

        coordinator.continueWithLanOnly();
        expect(
          coordinator.state.recommendedAction,
          equals(CapabilityActionType.none),
        );
        expect(coordinator.state.canUseLan, isTrue);

        coordinator.dispose();
      },
    );

    test('automatically refreshes on AppLifecycleState.resumed', () async {
      final platform = _MockTestPlatformService(
        const SystemCapabilities(
          platformName: 'android',
          bluetoothState: RadioState.disabled,
          nearbyPermission: PermissionStatus.notRequested,
          lanState: NetworkState.disconnected,
        ),
      );

      var reconciled = false;
      final coordinator = CapabilityCoordinator(
        platformService: platform,
        lifecycleManager: lifecycleManager,
        initialCapabilities: platform.currentCaps,
        onCapabilitiesChanged: () async {
          reconciled = true;
        },
      );

      expect(
        coordinator.state.operationalStatus,
        equals(CapabilityOperationalStatus.actionRequired),
      );

      // Simulate user turning on Wi-Fi and Bluetooth outside the app
      platform.currentCaps = const SystemCapabilities(
        platformName: 'android',
        bluetoothState: RadioState.enabled,
        nearbyPermission: PermissionStatus.granted,
        lanState: NetworkState.lanAvailable,
      );

      // App goes to background then resumes
      lifecycleManager.didChangeAppLifecycleState(AppLifecycleState.paused);
      lifecycleManager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(reconciled, isTrue);
      expect(
        coordinator.state.operationalStatus,
        equals(CapabilityOperationalStatus.readyBoth),
      );

      coordinator.dispose();
    });
  });
}
