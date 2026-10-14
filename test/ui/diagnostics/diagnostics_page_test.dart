import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

void main() {
  group('DiagnosticsPage Widget Tests (UI11 & Section 32)', () {
    late LocalDeviceIdentity localIdentity;
    late AppContainer container;
    late _MockDiscoveryService mockDiscoveryService;
    late _MockBatteryProvider mockBatteryProvider;

    setUp(() async {
      localIdentity = LocalDeviceIdentity.generate(
        displayName: 'Diagnostics-Device',
        platform: 'android',
      );
      mockDiscoveryService = _MockDiscoveryService(TransportType.lan);
      final coordinator = DiscoveryCoordinator(
        services: [mockDiscoveryService],
      );
      mockBatteryProvider = _MockBatteryProvider(
        initialSnapshot: BatterySnapshot(
          batteryLevel: 77,
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

    testWidgets('Renders all telemetry cards faithfully without private keys', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(home: DiagnosticsPage(container: container)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Diagnostics & Telemetry'), findsOneWidget);
      expect(find.text('Android & System Platform'), findsOneWidget);
      expect(find.text('Bluetooth Low Energy (BLE)'), findsOneWidget);
      expect(find.text('Local Area Network (LAN)'), findsOneWidget);
      expect(find.text('Near Field Communication (NFC)'), findsOneWidget);
      expect(find.text('Permissions State'), findsOneWidget);
      expect(find.text('Security & Cryptographic Identity'), findsOneWidget);
      expect(find.text('Battery & Power Conservation'), findsOneWidget);
      expect(find.text('Transfer Engine & State Machine'), findsOneWidget);

      // Verify device display name and ID are shown
      expect(find.text('Diagnostics-Device'), findsOneWidget);

      // Verify battery level is truthfully rendered
      expect(find.text('77%'), findsOneWidget);
      expect(find.text('Charging / Plugged in'), findsOneWidget);

      // Strict security verification: ensure NO private key text is ever rendered
      expect(find.textContaining('privateKey'), findsNothing);
      expect(find.textContaining('seed'), findsNothing);
      expect(find.text('Protected & Never Displayed'), findsOneWidget);
    });

    testWidgets('Copy diagnostics button interacts with Clipboard', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
            return null;
          }
          return null;
        },
      );

      await tester.pumpWidget(
        MaterialApp(home: DiagnosticsPage(container: container)),
      );
      await tester.pumpAndSettle();

      // Tap copy button in AppBar
      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Diagnostics copied to clipboard'), findsOneWidget);
      expect(clipboardText, isNotNull);
      expect(clipboardText, contains('# Vayu Diagnostics Report'));
      expect(clipboardText, contains('Diagnostics-Device'));
      expect(clipboardText, contains('level=77%'));
    });
  });
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

class _MockDiscoveryService implements DiscoveryService {
  @override
  final TransportType transportType;
  final StreamController<DiscoveredPeer> _controller =
      StreamController<DiscoveredPeer>.broadcast();

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

  void dispose() {
    _controller.close();
  }
}
