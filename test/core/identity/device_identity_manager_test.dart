import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/device_identity_manager.dart';
import 'package:vayu/core/identity/identity_storage.dart';

void main() {
  group('DeviceIdentityManager Tests', () {
    late InMemoryIdentityStorage inMemoryStorage;
    late DeviceIdentityManager manager;

    setUp(() {
      inMemoryStorage = InMemoryIdentityStorage();
      manager = DeviceIdentityManager(inMemoryStorage);
    });

    tearDown(() async {
      await manager.dispose();
    });

    test('mints and persists fresh identity on first boot', () async {
      expect(manager.currentIdentity, isNull);

      final identity = await manager.getOrInitializeIdentity(
        defaultDisplayName: 'My Pixel Phone',
        platform: 'android',
      );

      expect(identity.displayName, equals('My Pixel Phone'));
      expect(identity.platform, equals('android'));
      expect(manager.currentIdentity, equals(identity));

      // Verify stored in underlying persistence
      final stored = await inMemoryStorage.loadIdentity();
      expect(stored?.uuid, equals(identity.uuid));
    });

    test(
      'loads existing identity on subsequent boots without re-minting',
      () async {
        // First boot
        final initial = await manager.getOrInitializeIdentity(
          defaultDisplayName: 'Initial Device',
          platform: 'android',
        );

        // Create a second manager pointing to the same storage (simulating app restart)
        final secondManager = DeviceIdentityManager(inMemoryStorage);
        final restored = await secondManager.getOrInitializeIdentity(
          defaultDisplayName: 'Different Name',
          platform: 'android',
        );

        expect(restored.uuid, equals(initial.uuid));
        expect(
          restored.displayName,
          equals('Initial Device'),
        ); // Keeps original saved name
        await secondManager.dispose();
      },
    );

    test(
      'updates display name, persists change, and emits to stream',
      () async {
        final initial = await manager.getOrInitializeIdentity(
          defaultDisplayName: 'Old Name',
          platform: 'android',
        );

        final streamValues = <String>[];
        final subscription = manager.identityStream.listen((id) {
          streamValues.add(id.displayName);
        });

        await manager.updateDisplayName('Renamed Device');

        expect(manager.currentIdentity?.displayName, equals('Renamed Device'));
        expect(
          manager.currentIdentity?.uuid,
          equals(initial.uuid),
        ); // UUID unchanged

        final stored = await inMemoryStorage.loadIdentity();
        expect(stored?.displayName, equals('Renamed Device'));

        // Allow stream microtasks to flush
        await Future<void>.delayed(Duration.zero);
        expect(streamValues, contains('Renamed Device'));

        await subscription.cancel();
      },
    );

    test('rejects empty display name update', () async {
      await manager.getOrInitializeIdentity(
        defaultDisplayName: 'Device 1',
        platform: 'android',
      );

      expect(
        () => manager.updateDisplayName('   '),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('FileIdentityStorage Tests', () {
    late Directory tempDir;
    late File identityFile;
    late FileIdentityStorage fileStorage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vayu_test_');
      identityFile = File('${tempDir.path}/identity.json');
      fileStorage = FileIdentityStorage(identityFile);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('saves, reads, and clears identity from disk file', () async {
      expect(await fileStorage.loadIdentity(), isNull);

      final manager = DeviceIdentityManager(fileStorage);
      final identity = await manager.getOrInitializeIdentity(
        defaultDisplayName: 'Disk Persisted Device',
        platform: 'android',
      );

      expect(await identityFile.exists(), isTrue);

      // Reload with new storage instance
      final reloadStorage = FileIdentityStorage(identityFile);
      final loaded = await reloadStorage.loadIdentity();

      expect(loaded?.uuid, equals(identity.uuid));
      expect(loaded?.displayName, equals('Disk Persisted Device'));

      // Clear
      await fileStorage.clearIdentity();
      expect(await identityFile.exists(), isFalse);
      expect(await fileStorage.loadIdentity(), isNull);

      await manager.dispose();
    });
  });
}
