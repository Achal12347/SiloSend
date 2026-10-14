import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/device_identity_manager.dart';
import 'package:vayu/core/identity/device_name_generator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/domain/discovery/discovery_beacon.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

void main() {
  test('the same device ID always gives the same name', () {
    final id = Uint8List.fromList(List.generate(16, (i) => i * 13));
    expect(
      DeviceNameGenerator.forDeviceId(id),
      DeviceNameGenerator.forDeviceId(Uint8List.fromList(id)),
    );
  });

  test('names are readable and fit the discovery beacon', () {
    final pattern = RegExp(r'^Vayu-[A-Z][a-z]+[A-Z][a-z]+-[2-9A-HJ-NP-Z]{2}$');
    for (var seed = 0; seed < 256; seed++) {
      final id = Uint8List.fromList(
        List.generate(16, (i) => (seed * 31 + i * 7) & 0xff),
      );
      final name = DeviceNameGenerator.forDeviceId(id);
      expect(name, matches(pattern));
      expect(
        name.length,
        lessThanOrEqualTo(DiscoveryBeacon.maxDisplayNameBytes),
      );
    }
  });

  test('random device IDs rarely share a name', () {
    // Real IDs are random bytes; 32 x 32 x 32 x 32 = ~1M possible names.
    final random = Random(42);
    final names = {
      for (var n = 0; n < 200; n++)
        DeviceNameGenerator.forDeviceId(
          Uint8List.fromList(List.generate(16, (_) => random.nextInt(256))),
        ),
    };
    expect(names.length, greaterThanOrEqualTo(198));
  });

  test('a new install gets a generated name, not the shared default', () async {
    final manager = DeviceIdentityManager(InMemoryIdentityStorage());
    final identity = await manager.getOrCreateIdentity();
    expect(identity.displayName, isNot(DeviceNameGenerator.legacyDefaultName));
    expect(
      identity.displayName,
      DeviceNameGenerator.forDeviceId(identity.deviceId),
    );
  });

  test('an old install still named Vayu-Device is renamed once', () async {
    final old = LocalDeviceIdentity.generate(
      displayName: DeviceNameGenerator.legacyDefaultName,
      platform: 'android',
    );
    final storage = InMemoryIdentityStorage(old);
    final identity = await DeviceIdentityManager(storage).getOrCreateIdentity();
    expect(identity.deviceId, old.deviceId);
    expect(identity.displayName, DeviceNameGenerator.forDeviceId(old.deviceId));
    expect((await storage.loadIdentity())!.displayName, identity.displayName);
  });

  test('a name the user chose is kept', () async {
    final mine = LocalDeviceIdentity.generate(
      displayName: "Achal's phone",
      platform: 'android',
    );
    final identity = await DeviceIdentityManager(InMemoryIdentityStorage(mine))
        .getOrCreateIdentity();
    expect(identity.displayName, "Achal's phone");
  });
}
