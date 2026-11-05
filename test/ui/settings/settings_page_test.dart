import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/diagnostics/diagnostics_page.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/ui/settings/about_page.dart';
import 'package:vayu/ui/settings/device_name_page.dart';
import 'package:vayu/ui/settings/settings_page.dart';

void main() {
  group('SettingsPage Widget Tests (UI10 & UI9)', () {
    late LocalDeviceIdentity localIdentity;
    late AppContainer container;
    late _MockDiscoveryService mockDiscoveryService;
    late _MockBatteryProvider mockBatteryProvider;

    setUp(() async {
      localIdentity = LocalDeviceIdentity.generate(
        displayName: 'Initial-Device-Name',
        platform: 'android',
      );
      mockDiscoveryService = _MockDiscoveryService(TransportType.lan);
      final coordinator = DiscoveryCoordinator(
        services: [mockDiscoveryService],
      );
      mockBatteryProvider = _MockBatteryProvider(
        initialSnapshot: BatterySnapshot(
          batteryLevel: 80,
          isCharging: true,
          isBatterySaverActive: false,
          timestamp: DateTime.now(),
        ),
      );

      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(localIdentity),
        settingsStorage: InMemorySettingsStorage(),
        discoveryCoordinator: coordinator,
        batteryProvider: mockBatteryProvider,
      );
      await container.initialize();
    });

    tearDown(() {
      container.dispose();
      mockDiscoveryService.dispose();
    });

    testWidgets('Renders all settings sections and current device name', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(container: container)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Initial-Device-Name'), findsOneWidget);
      expect(find.text('Battery saver'), findsOneWidget);
      // Toggles and links only: nothing here just explains things.
      expect(find.text('Received files'), findsNothing);
      expect(find.text('Receiving'), findsNothing);
      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('Diagnostics'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('Allows editing device display name', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(container: container)),
      );
      await tester.pumpAndSettle();

      // A page of its own, not a popup.
      await tester.tap(find.text('Phone name'));
      await tester.pumpAndSettle();

      expect(find.byType(DeviceNamePage), findsOneWidget);

      // Enter new name
      await tester.enterText(find.byType(TextFormField), 'Updated-Phone-01');
      // Saving runs against the real container, outside the fake clock.
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      // Verify display name updated on container
      expect(container.identity?.displayName, 'Updated-Phone-01');
      expect(container.userSettings.customDisplayName, 'Updated-Phone-01');
      expect(find.text('Updated-Phone-01'), findsOneWidget);
    });

    testWidgets(
      'Toggling Battery Saver mode updates state and throttles discovery',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(home: SettingsPage(container: container)),
        );
        await tester.pumpAndSettle();

        // Tap 'On' segment
        await tester.tap(find.text('On'));
        await tester.pumpAndSettle();

        expect(container.userSettings.batterySaverMode, BatterySaverMode.on);
        expect(
          container.orchestrator.currentState.isBatterySaverActive,
          isTrue,
        );
        expect(container.discoveryCoordinator.isBatterySaverActive, isTrue);

        // Tap 'Off' segment
        await tester.tap(find.text('Off'));
        await tester.pumpAndSettle();

        expect(container.userSettings.batterySaverMode, BatterySaverMode.off);
        expect(
          container.orchestrator.currentState.isBatterySaverActive,
          isFalse,
        );
        expect(container.discoveryCoordinator.isBatterySaverActive, isFalse);
      },
    );

    testWidgets('About is a page with version, brand and links', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(container: container)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.text('Version 0.1.0 alpha'), findsOneWidget);
      expect(find.text('by Achyrio'), findsOneWidget);
      expect(find.text(AppConstants.developerName), findsOneWidget);
      expect(find.text('github.com/Achal12347'), findsOneWidget);
      expect(find.text('github.com/Achal12347/SiloSend'), findsOneWidget);
    });

    test('the shown version matches pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('version: ${AppConstants.appVersion}+'));
    });

    testWidgets('Navigates to Diagnostics & Telemetry page', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(container: container)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();

      expect(find.byType(DiagnosticsPage), findsOneWidget);
      expect(find.text('Android & System Platform'), findsOneWidget);
    });
  });
}

class _MockBatteryProvider implements BatteryStateProvider {
  BatterySnapshot _snapshot;

  _MockBatteryProvider({required BatterySnapshot initialSnapshot})
    : _snapshot = initialSnapshot;

  void update(BatterySnapshot snapshot) {
    _snapshot = snapshot;
  }

  @override
  Future<int?> getBatteryLevel() async => _snapshot.batteryLevel;

  @override
  Future<bool?> isCharging() async => _snapshot.isCharging;

  @override
  Future<bool?> isBatterySaverActive() async => _snapshot.isBatterySaverActive;

  @override
  Future<BatterySnapshot> getBatterySnapshot() async => _snapshot;
}

class _MockDiscoveryService implements DiscoveryService {
  @override
  final TransportType transportType;
  final StreamController<DiscoveredPeer> _controller =
      StreamController<DiscoveredPeer>.broadcast();

  bool isScanning = false;
  bool isAdvertising = false;
  DeviceAdvertisement? currentAd;

  _MockDiscoveryService(this.transportType);

  @override
  Stream<DiscoveredPeer> get discoveredPeers => _controller.stream;

  @override
  Future<void> startDiscovery() async {
    isScanning = true;
  }

  @override
  Future<void> stopDiscovery() async {
    isScanning = false;
  }

  @override
  Future<void> startAdvertising(DeviceAdvertisement advertisement) async {
    isAdvertising = true;
    currentAd = advertisement;
  }

  @override
  Future<void> stopAdvertising() async {
    isAdvertising = false;
    currentAd = null;
  }

  void emitPeer(DiscoveredPeer peer) {
    _controller.add(peer);
  }

  void dispose() {
    _controller.close();
  }
}
