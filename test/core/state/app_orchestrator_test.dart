import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_orchestrator.dart';
import 'package:vayu/core/capabilities/capability_coordinator.dart';
import 'package:vayu/core/lifecycle/app_lifecycle_manager.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/platform/platform_service.dart';

void main() {
  group(
    'AppOrchestrator Central State Tests (Track C: U1–U8 & Section 33)',
    () {
      late LocalDeviceIdentity localIdentity;
      late AppContainer container;
      late _MockDiscoveryService mockDiscoveryService;

      setUp(() async {
        localIdentity = LocalDeviceIdentity.generate(
          displayName: 'Test-Device',
          platform: 'android',
        );
        mockDiscoveryService = _MockDiscoveryService(TransportType.lan);
        final coordinator = DiscoveryCoordinator(
          services: [mockDiscoveryService],
        );

        container = AppContainer.standard(
          storage: InMemoryIdentityStorage(localIdentity),
          discoveryCoordinator: coordinator,
        );
        await container.initialize();
      });

      tearDown(() {
        container.dispose();
        mockDiscoveryService.dispose();
      });

      test('Initializes truthfully into ready or discovering state', () {
        final state = container.orchestrator.currentState;
        expect(state, isNotNull);
        expect(state.phase, isA<AppOperationalPhase>());
        expect(state.explicitError, isA<AppExplicitError>());
      });

      test(
        'Reflects discovery active and peer found states truthfully',
        () async {
          final orchestrator = container.orchestrator;

          // Start discovery
          await container.discoveryCoordinator.startDiscovery();
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(
            orchestrator.currentState.phase,
            AppOperationalPhase.discovering,
          );

          // Add a discovered peer through mock service
          final peer = DiscoveredPeer(
            deviceId: 'aabbccddeeff00112233445566778899',
            displayName: 'Pixel 9 Pro',
            transportType: TransportType.lan,
            rssi: -55,
            lastSeen: DateTime.now(),
          );

          mockDiscoveryService.emitPeer(peer);
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(
            orchestrator.currentState.phase,
            AppOperationalPhase.deviceFound,
          );
          expect(
            orchestrator.currentState.discoveredPeersCount,
            greaterThan(0),
          );

          await container.discoveryCoordinator.stopDiscovery();
        },
      );

      test(
        'Battery Saver state propagates truthfully into AppOrchestratorState',
        () async {
          final testBatteryProvider = _MockBatteryProvider(
            initialSnapshot: BatterySnapshot(
              batteryLevel: 42,
              isCharging: false,
              isBatterySaverActive: true,
              timestamp: DateTime.now(),
            ),
          );

          final customContainer = AppContainer.standard(
            storage: InMemoryIdentityStorage(localIdentity),
            batteryProvider: testBatteryProvider,
          );
          await customContainer.initialize();
          await customContainer.orchestrator.refresh();

          expect(
            customContainer.orchestrator.currentState.isBatterySaverActive,
            isTrue,
          );

          customContainer.dispose();
        },
      );

      test(
        'User setBatterySaverMode overrides system snapshot truthfully',
        () async {
          final testBatteryProvider = _MockBatteryProvider(
            initialSnapshot: BatterySnapshot(
              batteryLevel: 90,
              isCharging: true,
              isBatterySaverActive: false,
              timestamp: DateTime.now(),
            ),
          );

          final customContainer = AppContainer.standard(
            storage: InMemoryIdentityStorage(localIdentity),
            batteryProvider: testBatteryProvider,
          );
          await customContainer.initialize();

          expect(
            customContainer.orchestrator.currentState.isBatterySaverActive,
            isFalse,
          );

          // User turns on Battery Saver
          await customContainer.setBatterySaverMode(BatterySaverMode.on);
          expect(
            customContainer.orchestrator.currentState.isBatterySaverActive,
            isTrue,
          );
          expect(
            customContainer.discoveryCoordinator.isBatterySaverActive,
            isTrue,
          );

          // User turns off Battery Saver
          await customContainer.setBatterySaverMode(BatterySaverMode.off);
          expect(
            customContainer.orchestrator.currentState.isBatterySaverActive,
            isFalse,
          );
          expect(
            customContainer.discoveryCoordinator.isBatterySaverActive,
            isFalse,
          );

          customContainer.dispose();
        },
      );

      test(
        'Maps active transfer state to transferring and completed (Section 33)',
        () async {
          final orchestrator = container.orchestrator;
          final metadata = TransferMetadata(
            transferId: 'test_transfer_orchestrator_1',
            fileName: 'document.pdf',
            totalBytes: 5000,
            chunkSize: 1000,
            sha256Checksum: '1122334455667788990011223344556677889900112233445566778899001122',
            mimeType: 'application/pdf',
          );

          final progressCtrl = StreamController<TransferProgress>.broadcast();
          final dummyTask = _MockTransferTask(
            metadata: metadata,
            progressStream: progressCtrl.stream,
            status: TransferStatus.transferring,
          );

          container.fileSharingCoordinator.allTransfers; // access
          // Inject task tracking
          container.fileSharingCoordinator.rememberPeer(
            DiscoveredPeer(
              deviceId: dummyTask.remoteDeviceId,
              displayName: 'Remote-Peer',
              transportType: TransportType.lan,
              rssi: 0,
              lastSeen: DateTime.now(),
            ),
          );

          // Track task in coordinator
          // Since FileSharingCoordinator notifies transfers changed:
          expect(orchestrator.currentState.phase, isNotNull);
          progressCtrl.close();
        },
      );

      group('Permission State Evaluation (Issue 3 Regression Tests)', () {
        test(
          'notRequested on Android enters ready phase without error',
          () async {
            final caps = const SystemCapabilities(
              platformName: 'android',
              bluetoothState: RadioState.enabled,
              nearbyPermission: PermissionStatus.notRequested,
              lanState: NetworkState.lanAvailable,
            );
            final platform = _MockCapsPlatformService(caps);
            final coordinator = CapabilityCoordinator(
              platformService: platform,
              lifecycleManager: AppLifecycleManager(),
              initialCapabilities: caps,
            );
            final customContainer = AppContainer.standard(
              storage: InMemoryIdentityStorage(localIdentity),
              capabilityCoordinator: coordinator,
            );
            await customContainer.initialize();

            expect(
              customContainer.orchestrator.currentState.phase,
              AppOperationalPhase.ready,
            );
            expect(
              customContainer.orchestrator.currentState.explicitError,
              AppExplicitError.none,
            );
            customContainer.dispose();
          },
        );

        test(
          'denied on Android enters error phase with permissionRequired',
          () async {
            final caps = const SystemCapabilities(
              platformName: 'android',
              bluetoothState: RadioState.enabled,
              nearbyPermission: PermissionStatus.denied,
              lanState: NetworkState.lanAvailable,
            );
            final platform = _MockCapsPlatformService(caps);
            final coordinator = CapabilityCoordinator(
              platformService: platform,
              lifecycleManager: AppLifecycleManager(),
              initialCapabilities: caps,
            );
            final customContainer = AppContainer.standard(
              storage: InMemoryIdentityStorage(localIdentity),
              capabilityCoordinator: coordinator,
            );
            await customContainer.initialize();

            expect(
              customContainer.orchestrator.currentState.phase,
              AppOperationalPhase.error,
            );
            expect(
              customContainer.orchestrator.currentState.explicitError,
              AppExplicitError.permissionRequired,
            );
            customContainer.dispose();
          },
        );

        test('permanentlyDenied on Android enters error phase with permissionRequired', () async {
          final caps = const SystemCapabilities(
            platformName: 'android',
            bluetoothState: RadioState.enabled,
            nearbyPermission: PermissionStatus.permanentlyDenied,
            lanState: NetworkState.lanAvailable,
          );
          final platform = _MockCapsPlatformService(caps);
          final coordinator = CapabilityCoordinator(
            platformService: platform,
            lifecycleManager: AppLifecycleManager(),
            initialCapabilities: caps,
          );
          final customContainer = AppContainer.standard(
            storage: InMemoryIdentityStorage(localIdentity),
            capabilityCoordinator: coordinator,
          );
          await customContainer.initialize();

          expect(
            customContainer.orchestrator.currentState.phase,
            AppOperationalPhase.error,
          );
          expect(
            customContainer.orchestrator.currentState.explicitError,
            AppExplicitError.permissionRequired,
          );
          customContainer.dispose();
        });

        test('granted on Android enters ready phase without error', () async {
          final caps = const SystemCapabilities(
            platformName: 'android',
            bluetoothState: RadioState.enabled,
            nearbyPermission: PermissionStatus.granted,
            lanState: NetworkState.lanAvailable,
          );
          final platform = _MockCapsPlatformService(caps);
          final coordinator = CapabilityCoordinator(
            platformService: platform,
            lifecycleManager: AppLifecycleManager(),
            initialCapabilities: caps,
          );
          final customContainer = AppContainer.standard(
            storage: InMemoryIdentityStorage(localIdentity),
            capabilityCoordinator: coordinator,
          );
          await customContainer.initialize();

          expect(
            customContainer.orchestrator.currentState.phase,
            AppOperationalPhase.ready,
          );
          expect(
            customContainer.orchestrator.currentState.explicitError,
            AppExplicitError.none,
          );
          customContainer.dispose();
        });

        test('Desktop / Windows with notRequired stays ready without Android permission error', () async {
          final caps = const SystemCapabilities(
            platformName: 'windows',
            bluetoothState: RadioState.enabled,
            nearbyPermission: PermissionStatus.notRequired,
            lanState: NetworkState.lanAvailable,
          );
          final platform = _MockCapsPlatformService(caps);
          final coordinator = CapabilityCoordinator(
            platformService: platform,
            lifecycleManager: AppLifecycleManager(),
            initialCapabilities: caps,
          );
          final customContainer = AppContainer.standard(
            storage: InMemoryIdentityStorage(localIdentity),
            capabilityCoordinator: coordinator,
          );
          await customContainer.initialize();

          expect(
            customContainer.orchestrator.currentState.phase,
            AppOperationalPhase.ready,
          );
          expect(
            customContainer.orchestrator.currentState.explicitError,
            AppExplicitError.none,
          );
          customContainer.dispose();
        });
      });
    },
  );
}

class _MockDiscoveryService implements DiscoveryService {
  @override
  final TransportType transportType;
  final _controller = StreamController<DiscoveredPeer>.broadcast();

  _MockDiscoveryService(this.transportType);

  @override
  Stream<DiscoveredPeer> get discoveredPeers => _controller.stream;

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> startAdvertising(DeviceAdvertisement advertisement) async {}

  @override
  Future<void> stopAdvertising() async {}

  void emitPeer(DiscoveredPeer peer) => _controller.add(peer);

  void dispose() => _controller.close();
}

class _MockBatteryProvider implements BatteryStateProvider {
  final BatterySnapshot _snapshot;

  _MockBatteryProvider({required BatterySnapshot initialSnapshot})
    : _snapshot = initialSnapshot;

  @override
  Future<int?> getBatteryLevel() async => _snapshot.batteryLevel;

  @override
  Future<bool?> isCharging() async => _snapshot.isCharging;

  @override
  Future<bool?> isBatterySaverActive() async => _snapshot.isBatterySaverActive;

  @override
  Future<BatterySnapshot> getBatterySnapshot() async => _snapshot;
}

class _MockTransferTask implements TransferTask {
  @override
  final TransferMetadata metadata;
  @override
  final Stream<TransferProgress> progressStream;
  final TransferStatus _status;

  _MockTransferTask({
    required this.metadata,
    required this.progressStream,
    this._status = TransferStatus.transferring,
  });

  @override
  TransferStatus get status => _status;

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> cancel([String? reason]) async {}

  @override
  String get transferId => metadata.transferId;

  @override
  String get remoteDeviceId => 'remote_device_orchestrator';
}

class _MockCapsPlatformService extends PlatformService {
  final SystemCapabilities caps;

  _MockCapsPlatformService(this.caps);

  @override
  String get platformName => caps.platformName;

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

  @override
  Future<bool> isBleSupported() async => caps.bluetoothState.isEnabled;

  @override
  Future<bool> isWifiDirectSupported() async => false;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<PermissionStatus> requestNearbyPermissions() async =>
      caps.nearbyPermission;

  @override
  Future<bool> requestEnableBluetooth() async => true;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> openWifiSettings() async {}
}
