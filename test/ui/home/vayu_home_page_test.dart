import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/ui/home/discovered_peer_card.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/system_platform_service.dart';
import 'package:vayu/ui/home/vayu_home_page.dart';

void main() {
  group('VayuHomePage Product Flow & State Composition Tests', () {
    late LocalDeviceIdentity identity;
    late AppContainer container;
    late MockDiscoveryService lanDiscovery;
    late MockDiscoveryService bleDiscovery;

    setUp(() async {
      identity = LocalDeviceIdentity(
        deviceId: Uint8List.fromList(List<int>.filled(16, 0x33)),
        displayName: 'My-Pixel-Device',
        createdAt: DateTime.now(),
        protocolVersion: 1,
        platform: 'android',
      );

      lanDiscovery = MockDiscoveryService(TransportType.lan);
      bleDiscovery = MockDiscoveryService(TransportType.ble);
      final discoveryCoordinator = DiscoveryCoordinator(
        services: [lanDiscovery, bleDiscovery],
      );

      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(identity),
        platformService: _FakeHomePlatformService(),
        lanServer: LanConnectionServer(requestedPort: 0),
        discoveryCoordinator: discoveryCoordinator,
      );
      await container.initialize();
    });

    tearDown(() async {
      await container.stopDiscoveryAndAdvertising();
      await container.lanServer?.stop();
      container.dispose();
      lanDiscovery.dispose();
      bleDiscovery.dispose();
    });

    testWidgets('renders Hero Send File card and connectivity chip', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(container: container, child: const VayuHomePage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // 1. Header branding; readiness text appears only when it matters
      expect(find.text('Vayu'), findsOneWidget);
      expect(find.textContaining('Ready ·'), findsNothing);

      // 2. Hero Section
      expect(find.text('Share files nearby'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Receive'), findsOneWidget);

      // 3. Nearby Devices section
      expect(find.text('Nearby devices'), findsOneWidget);

      // 4. Local device row (below the fold on small test surfaces)
      await tester.scrollUntilVisible(find.text('Your device'), 200);
      expect(find.text('Your device'), findsOneWidget);
      expect(find.text('My-Pixel-Device'), findsOneWidget);
      // Protocol internals are no longer on the home screen.
      expect(find.text('Device ID'), findsNothing);

      await container.stopDiscoveryAndAdvertising();
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets(
      'displays discovered peer with real transport badges and send action',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: AppScope(container: container, child: const VayuHomePage()),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Inject peer
        container.discoveryCoordinator.ingestPeerForTesting(
          DiscoveredPeer(
            deviceId: '44444444444444444444444444444444',
            displayName: 'Peer-Galaxy',
            transportType: TransportType.lan,
            availableTransports: {TransportType.lan, TransportType.ble},
            rssi: -55,
            lastSeen: DateTime.now(),
          ),
        );

        await tester.pump(const Duration(milliseconds: 100));

        // Peer row shows real reachability and an unverified identity honestly
        expect(find.text('Peer-Galaxy'), findsOneWidget);
        expect(find.text('New device'), findsOneWidget);
        // The peer row's own Send (the hero has the other one).
        expect(
          find.descendant(
            of: find.byType(DiscoveredPeerCard),
            matching: find.text('Send'),
          ),
          findsOneWidget,
        );

        // Manual connect lives in the row's menu
        await tester.tap(find.byTooltip('More'));
        await tester.pumpAndSettle();
        expect(find.text('Connect'), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await container.stopDiscoveryAndAdvertising();
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets('shows noDevices empty state after search window passes', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(container: container, child: const VayuHomePage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // Start discovery
      await container.startDiscoveryAndAdvertising();
      await tester.pump(const Duration(milliseconds: 100));

      // Simulate passing the initial search window (>= 4s)
      container.discoveryCoordinator.setDiscoveryStartedAtForTesting(
        DateTime.now().subtract(const Duration(seconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('No devices found yet'), findsOneWidget);
      expect(find.text('Search again'), findsOneWidget);

      await container.stopDiscoveryAndAdvertising();
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}

class _FakeHomePlatformService extends SystemPlatformService {
  @override
  String get platformName => 'android';

  @override
  Future<SystemCapabilities> checkCapabilities() async =>
      const SystemCapabilities(
        platformName: 'android',
        wifiEnabled: true,
        lanState: NetworkState.lanAvailable,
        bluetoothState: RadioState.enabled,
        nearbyPermission: PermissionStatus.granted,
      );
}

class MockDiscoveryService implements DiscoveryService {
  @override
  final TransportType transportType;
  final _controller = StreamController<DiscoveredPeer>.broadcast();

  bool isScanning = false;
  bool isAdvertising = false;

  MockDiscoveryService(this.transportType);

  @override
  Stream<DiscoveredPeer> get discoveredPeers => _controller.stream;

  @override
  Future<void> startDiscovery() async => isScanning = true;

  @override
  Future<void> stopDiscovery() async => isScanning = false;

  @override
  Future<void> startAdvertising(DeviceAdvertisement advertisement) async =>
      isAdvertising = true;

  @override
  Future<void> stopAdvertising() async => isAdvertising = false;

  void emitPeer(DiscoveredPeer peer) => _controller.add(peer);

  void dispose() => _controller.close();
}
