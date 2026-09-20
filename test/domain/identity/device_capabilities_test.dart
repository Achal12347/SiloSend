import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/domain/identity/device_capabilities.dart';

void main() {
  group('DeviceCapabilities Tests', () {
    test('serializes and deserializes correctly', () {
      const capabilities = DeviceCapabilities(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: true,
        supportsNfc: false,
        hasCamera: true,
      );

      final json = capabilities.toJson();
      final restored = DeviceCapabilities.fromJson(json);

      expect(restored.supportsBle, isTrue);
      expect(restored.supportsBleAdvertising, isTrue);
      expect(restored.supportsWifiDirect, isTrue);
      expect(restored.supportsNfc, isFalse);
      expect(restored.hasCamera, isTrue);
    });

    test('none baseline provides all false values', () {
      const none = DeviceCapabilities.none;
      expect(none.supportsBle, isFalse);
      expect(none.supportsBleAdvertising, isFalse);
      expect(none.supportsWifiDirect, isFalse);
      expect(none.supportsNfc, isFalse);
      expect(none.hasCamera, isFalse);
    });
  });
}
