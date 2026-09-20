import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/domain/identity/device_capabilities.dart';

void main() {
  group('DeviceCapabilities Tests', () {
    test('serializes and deserializes correctly with CapabilityStatus', () {
      const capabilities = DeviceCapabilities(
        ble: CapabilityStatus.supported,
        bleAdvertising: CapabilityStatus.supported,
        wifiDirect: CapabilityStatus.supported,
        nfc: CapabilityStatus.unsupported,
        camera: CapabilityStatus.unavailable,
      );

      final json = capabilities.toJson();
      final restored = DeviceCapabilities.fromJson(json);

      expect(restored.ble, equals(CapabilityStatus.supported));
      expect(restored.supportsBle, isTrue);

      expect(restored.bleAdvertising, equals(CapabilityStatus.supported));
      expect(restored.supportsBleAdvertising, isTrue);

      expect(restored.wifiDirect, equals(CapabilityStatus.supported));
      expect(restored.supportsWifiDirect, isTrue);

      expect(restored.nfc, equals(CapabilityStatus.unsupported));
      expect(restored.supportsNfc, isFalse);

      expect(restored.camera, equals(CapabilityStatus.unavailable));
      expect(restored.supportsCamera, isFalse);
    });

    test('none baseline provides all unsupported values', () {
      const none = DeviceCapabilities.none;
      expect(none.ble, equals(CapabilityStatus.unsupported));
      expect(none.supportsBle, isFalse);
      expect(none.supportsBleAdvertising, isFalse);
      expect(none.supportsWifiDirect, isFalse);
      expect(none.supportsNfc, isFalse);
      expect(none.hasCamera, isFalse);
    });

    test(
      'unknown baseline provides all unknown values without false positives',
      () {
        const unknown = DeviceCapabilities.unknown;
        expect(unknown.ble, equals(CapabilityStatus.unknown));
        expect(unknown.supportsBle, isFalse);
        expect(unknown.wifiDirect, equals(CapabilityStatus.unknown));
        expect(unknown.supportsWifiDirect, isFalse);
        expect(unknown.camera, equals(CapabilityStatus.unknown));
        expect(unknown.hasCamera, isFalse);
      },
    );

    test('supports backward-compatible fromBooleans constructor', () {
      const capabilities = DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: false,
        supportsWifiDirect: true,
        supportsNfc: false,
        hasCamera: true,
      );

      expect(capabilities.ble, equals(CapabilityStatus.supported));
      expect(capabilities.bleAdvertising, equals(CapabilityStatus.unsupported));
      expect(capabilities.supportsWifiDirect, isTrue);
      expect(capabilities.supportsNfc, isFalse);
      expect(capabilities.supportsCamera, isTrue);
    });
  });
}
