import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/constants/app_constants.dart';
import 'package:silosend_datasharing_app/domain/identity/local_device_identity.dart';

void main() {
  group('LocalDeviceIdentity Tests', () {
    test(
      'generates valid 16-byte UUID identity with proper version/variant',
      () {
        final identity = LocalDeviceIdentity.generate(
          displayName: 'Pixel 8 Pro',
          platform: 'android',
        );

        expect(identity.deviceId.length, equals(16));
        expect(identity.displayName, equals('Pixel 8 Pro'));
        expect(identity.platform, equals('android'));
        expect(identity.protocolVersion, equals(AppConstants.protocolVersion));

        // Check hex string representation (32 hex characters)
        expect(identity.idHex.length, equals(32));
        expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(identity.idHex), isTrue);

        // Check UUID format (8-4-4-4-12)
        final uuidRegex = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        );
        expect(uuidRegex.hasMatch(identity.uuid), isTrue);
      },
    );

    test('serializes to and from JSON correctly', () {
      final original = LocalDeviceIdentity.generate(
        displayName: 'Test Device',
        platform: 'windows',
      );

      final json = original.toJson();
      final restored = LocalDeviceIdentity.fromJson(json);

      expect(restored.deviceId, equals(original.deviceId));
      expect(restored.idHex, equals(original.idHex));
      expect(restored.uuid, equals(original.uuid));
      expect(restored.displayName, equals(original.displayName));
      expect(restored.platform, equals(original.platform));
      expect(restored.protocolVersion, equals(original.protocolVersion));
      expect(restored.createdAt, equals(original.createdAt));
    });

    test('supports copyWith for display name mutation', () {
      final identity = LocalDeviceIdentity.generate(
        displayName: 'Original Name',
        platform: 'android',
      );

      final updated = identity.copyWith(displayName: 'New Name');
      expect(updated.displayName, equals('New Name'));
      expect(updated.deviceId, equals(identity.deviceId));
      expect(updated.createdAt, equals(identity.createdAt));
    });

    test('rejects empty or whitespace-only display name', () {
      expect(
        () => LocalDeviceIdentity.generate(
          displayName: '   ',
          platform: 'android',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
