import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/platform/system_platform_service.dart';

void main() {
  group('SystemPlatformService Tests', () {
    test('reports truthful platform name', () {
      final service = SystemPlatformService(platformNameOverride: 'android');
      expect(service.platformName, equals('android'));

      final defaultService = SystemPlatformService();
      expect(defaultService.platformName, isNotEmpty);
    });

    test('returns unknown capability baseline without fake claims', () async {
      final service = SystemPlatformService(platformNameOverride: 'android');
      final capabilities = await service.getCapabilities();

      expect(capabilities.ble, equals(CapabilityStatus.unknown));
      expect(capabilities.bleAdvertising, equals(CapabilityStatus.unknown));
      expect(capabilities.wifiDirect, equals(CapabilityStatus.unknown));
      expect(capabilities.nfc, equals(CapabilityStatus.unknown));
      expect(capabilities.camera, equals(CapabilityStatus.unknown));

      // Convenience booleans must report false because they are not confirmed supported
      expect(capabilities.supportsBle, isFalse);
      expect(capabilities.supportsBleAdvertising, isFalse);
      expect(capabilities.supportsWifiDirect, isFalse);
      expect(capabilities.supportsNfc, isFalse);
      expect(capabilities.hasCamera, isFalse);

      expect(await service.isBleSupported(), isFalse);
      expect(await service.isWifiDirectSupported(), isFalse);
    });

    test(
      'accepts custom probe when real platform channel is attached',
      () async {
        final service = SystemPlatformService(
          platformNameOverride: 'android',
          customProbe: () async => const DeviceCapabilities(
            ble: CapabilityStatus.supported,
            bleAdvertising: CapabilityStatus.supported,
            wifiDirect: CapabilityStatus.supported,
            nfc: CapabilityStatus.unavailable,
            camera: CapabilityStatus.supported,
          ),
        );

        final capabilities = await service.getCapabilities();
        expect(capabilities.ble, equals(CapabilityStatus.supported));
        expect(capabilities.supportsBle, isTrue);
        expect(capabilities.wifiDirect, equals(CapabilityStatus.supported));
        expect(capabilities.supportsWifiDirect, isTrue);
        expect(capabilities.nfc, equals(CapabilityStatus.unavailable));
        expect(capabilities.supportsNfc, isFalse);

        expect(await service.isBleSupported(), isTrue);
        expect(await service.isWifiDirectSupported(), isTrue);
      },
    );

    test('requestPermissions reports false when unintegrated', () async {
      final service = SystemPlatformService();
      expect(await service.requestPermissions(), isFalse);
    });
  });
}
