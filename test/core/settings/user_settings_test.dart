import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/settings/user_settings.dart';

void main() {
  group('UserSettings & SettingsStorage Tests', () {
    test('Default values follow truthful system policy', () {
      const settings = UserSettings();
      expect(settings.batterySaverMode, BatterySaverMode.system);
      expect(settings.customDisplayName, isNull);
      expect(settings.customDownloadsPath, isNull);
    });

    test('Serializes and deserializes correctly to/from JSON', () {
      const settings = UserSettings(
        batterySaverMode: BatterySaverMode.on,
        customDisplayName: 'Pixel-Lab-01',
        customDownloadsPath: '/sdcard/Download/CustomSilo',
      );

      final json = settings.toJson();
      expect(json['batterySaverMode'], 'on');
      expect(json['customDisplayName'], 'Pixel-Lab-01');
      expect(json['customDownloadsPath'], '/sdcard/Download/CustomSilo');

      final reconstructed = UserSettings.fromJson(json);
      expect(reconstructed.batterySaverMode, BatterySaverMode.on);
      expect(reconstructed.customDisplayName, 'Pixel-Lab-01');
      expect(reconstructed.customDownloadsPath, '/sdcard/Download/CustomSilo');
    });

    test('Handles malformed or missing JSON gracefully without crashing', () {
      final fallback = UserSettings.fromJson({
        'batterySaverMode': 'non_existent_mode',
      });
      expect(fallback.batterySaverMode, BatterySaverMode.system);
    });

    test('InMemorySettingsStorage saves and loads faithfully', () async {
      final storage = InMemorySettingsStorage();
      final initial = await storage.loadSettings();
      expect(initial.batterySaverMode, BatterySaverMode.system);

      await storage.saveSettings(
        const UserSettings(batterySaverMode: BatterySaverMode.off),
      );
      final updated = await storage.loadSettings();
      expect(updated.batterySaverMode, BatterySaverMode.off);
    });

    test('FileSettingsStorage persists and reads from disk', () async {
      final tempDir = Directory.systemTemp.createTempSync('vayu_settings_test_');
      final file = File('${tempDir.path}/test_settings.json');

      try {
        final storage = FileSettingsStorage(file);
        // Initially non-existent file returns default
        final def = await storage.loadSettings();
        expect(def.batterySaverMode, BatterySaverMode.system);

        // Save new settings
        await storage.saveSettings(
          const UserSettings(
            batterySaverMode: BatterySaverMode.on,
            customDisplayName: 'Test-Device-File',
          ),
        );
        expect(await file.exists(), isTrue);

        // Read back
        final readBack = await storage.loadSettings();
        expect(readBack.batterySaverMode, BatterySaverMode.on);
        expect(readBack.customDisplayName, 'Test-Device-File');
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
