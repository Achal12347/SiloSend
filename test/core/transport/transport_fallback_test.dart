import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transport/smart_transport_selector_impl.dart';
import 'package:vayu/core/transport/transport_selection_policy.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/platform/platform_service.dart';

class _FallbackPlatformService extends PlatformService {
  @override
  String get platformName => 'android';
  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: false,
        supportsNfc: true,
        hasCamera: true,
      );
  @override
  Future<bool> isBleSupported() async => true;
  @override
  Future<bool> isWifiDirectSupported() async => false;
  @override
  Future<bool> requestPermissions() async => true;
}

class _FallbackBatteryProvider implements BatteryStateProvider {
  @override
  Future<int?> getBatteryLevel() async => 75;
  @override
  Future<bool?> isCharging() async => false;
  @override
  Future<bool?> isBatterySaverActive() async => false;
  @override
  Future<BatterySnapshot> getBatterySnapshot() async => BatterySnapshot(
    batteryLevel: 75,
    isCharging: false,
    isBatterySaverActive: false,
    timestamp: DateTime.now(),
  );
}

void main() {
  group('SmartTransportSelector Fallback Coordination Tests', () {
    late LocalDeviceIdentity localIdentity;
    late ConnectionManager connectionManager;
    late SecureSessionManager secureSessionManager;
    late SmartTransportSelectorImpl selector;

    setUp(() {
      localIdentity = LocalDeviceIdentity.generate(
        displayName: 'Fallback Tester',
        platform: 'android',
      );
      connectionManager = ConnectionManager(
        localIdentity: localIdentity,
        supportedTransports: {TransportType.lan, TransportType.ble},
      );
      secureSessionManager = SecureSessionManager(
        cryptoService: CryptoService(),
        trustStore: PeerTrustStore(),
        secureKeyStore: InMemorySecureKeyStore(),
        localIdentity: localIdentity,
      );
      selector = SmartTransportSelectorImpl(
        platformService: _FallbackPlatformService(),
        batteryProvider: _FallbackBatteryProvider(),
        connectionManager: connectionManager,
        secureSessionManager: secureSessionManager,
        policy: const TransportSelectionPolicy(),
      );
    });

    tearDown(() {
      connectionManager.dispose();
      secureSessionManager.dispose();
    });

    test('Fails with NoViableTransportException when all primary and fallback candidates fail', () async {
      // Remote peer advertising both LAN and BLE with non-existent endpoints
      final peer = DiscoveredPeer(
        deviceId: '00112233445566778899aabbccddeeff',
        displayName: 'Unreachable Peer',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan, TransportType.ble},
        rssi: -60,
        // IP 127.0.0.1 with invalid port that will immediately refuse connection
        endpointAddress: '127.0.0.1:59999',
        lastSeen: DateTime.now(),
      );

      // Request selection with small timeout to fail fast
      expect(
        () => selector.connectWithSmartSelection(
          peer,
          request: TransportSelectionRequest(
            targetPeer: peer,
            payloadSizeBytes: 50 * 1024, // 50 KB -> LAN preferred, BLE fallback
          ),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<NoViableTransportException>().having(
            (e) => e.attemptErrors.length,
            'attemptErrors count',
            greaterThanOrEqualTo(1),
          ),
        ),
      );
    });

    test('with Avoid LAN on, the shared Wi-Fi is never tried', () async {
      final avoiding = SmartTransportSelectorImpl(
        platformService: _FallbackPlatformService(),
        batteryProvider: _FallbackBatteryProvider(),
        connectionManager: connectionManager,
        secureSessionManager: secureSessionManager,
        avoidSharedWifi: () => true,
      );
      final peer = DiscoveredPeer(
        deviceId: '00112233445566778899aabbccddeeff',
        displayName: 'Same Wi-Fi',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan},
        rssi: -60,
        endpointAddress: '127.0.0.1:59999',
        lastSeen: DateTime.now(),
      );
      await expectLater(
        avoiding.connectDirectOnly(peer),
        // No attempt at all: a refused connection would be listed here.
        throwsA(
          isA<NoViableTransportException>().having(
            (e) => e.attemptErrors,
            'attemptErrors',
            isEmpty,
          ),
        ),
      );
    });

    test('selectTransport correctly identifies fallback chain for dual-transport peer', () async {
      final peer = DiscoveredPeer(
        deviceId: '112233445566778899aabbccddeeff00',
        displayName: 'Dual Peer',
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan, TransportType.ble},
        rssi: -60,
        endpointAddress: '192.168.1.100:53531',
        lastSeen: DateTime.now(),
      );

      final result = await selector.selectTransport(
        TransportSelectionRequest(
          targetPeer: peer,
          payloadSizeBytes: 60 * 1024,
        ),
      );

      expect(result.selectedTransport, TransportType.lan);
      expect(result.fallbackChain, contains(TransportType.ble));
      expect(result.rankedCandidates.length, greaterThanOrEqualTo(2));
      expect(result.rationale, contains('LAN'));
    });
  });
}
