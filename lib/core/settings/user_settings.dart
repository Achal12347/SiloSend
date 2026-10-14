import 'dart:convert';
import 'dart:io';

import 'package:vayu/core/logging/app_logger.dart';

/// User-configurable Battery Saver policy.
enum BatterySaverMode {
  /// Always off: standard discovery duty cycles and optimal transport throughput.
  off,

  /// Always on: throttles BLE scanning/advertising to low power and prioritizes battery conservation.
  on,

  /// Follow Android system: automatically applies battery saving when device Power Saver is active.
  system;

  String get displayName {
    switch (this) {
      case BatterySaverMode.off:
        return 'Off';
      case BatterySaverMode.on:
        return 'On';
      case BatterySaverMode.system:
        return 'Follow System';
    }
  }

  String get description {
    switch (this) {
      case BatterySaverMode.off:
        return 'Standard discovery and high-performance transport selection.';
      case BatterySaverMode.on:
        return 'Reduces background discovery duty cycles and optimizes transport selection for energy efficiency.';
      case BatterySaverMode.system:
        return 'Automatically applies power-saving optimizations when Android Power Saver is active.';
    }
  }
}

/// Appearance preference; [system] follows the phone's dark-mode setting.
enum AppThemePreference {
  system,
  light,
  dark;

  String get displayName {
    switch (this) {
      case AppThemePreference.system:
        return 'Follow System';
      case AppThemePreference.light:
        return 'Light';
      case AppThemePreference.dark:
        return 'Dark';
    }
  }
}

/// User application settings.
class UserSettings {
  final BatterySaverMode batterySaverMode;
  final AppThemePreference themePreference;
  final String? customDisplayName;
  final String? customDownloadsPath;

  const UserSettings({
    this.batterySaverMode = BatterySaverMode.system,
    this.themePreference = AppThemePreference.system,
    this.customDisplayName,
    this.customDownloadsPath,
  });

  UserSettings copyWith({
    BatterySaverMode? batterySaverMode,
    AppThemePreference? themePreference,
    String? customDisplayName,
    String? customDownloadsPath,
  }) {
    return UserSettings(
      batterySaverMode: batterySaverMode ?? this.batterySaverMode,
      themePreference: themePreference ?? this.themePreference,
      customDisplayName: customDisplayName ?? this.customDisplayName,
      customDownloadsPath: customDownloadsPath ?? this.customDownloadsPath,
    );
  }

  Map<String, dynamic> toJson() => {
    'batterySaverMode': batterySaverMode.name,
    'themePreference': themePreference.name,
    if (customDisplayName != null) 'customDisplayName': customDisplayName,
    if (customDownloadsPath != null) 'customDownloadsPath': customDownloadsPath,
  };

  factory UserSettings.fromJson(Map<String, dynamic> json) {
    var mode = BatterySaverMode.system;
    if (json['batterySaverMode'] != null) {
      try {
        mode = BatterySaverMode.values.byName(
          json['batterySaverMode'] as String,
        );
      } catch (_) {
        mode = BatterySaverMode.system;
      }
    }
    var theme = AppThemePreference.system;
    final rawTheme = json['themePreference'];
    if (rawTheme is String) {
      theme = AppThemePreference.values.firstWhere(
        (t) => t.name == rawTheme,
        orElse: () => AppThemePreference.system,
      );
    }
    return UserSettings(
      batterySaverMode: mode,
      themePreference: theme,
      customDisplayName: json['customDisplayName'] as String?,
      customDownloadsPath: json['customDownloadsPath'] as String?,
    );
  }
}

/// Abstract storage contract for persisting user settings.
abstract class SettingsStorage {
  Future<UserSettings> loadSettings();
  Future<void> saveSettings(UserSettings settings);
}

/// In-memory implementation of [SettingsStorage] for tests.
class InMemorySettingsStorage implements SettingsStorage {
  UserSettings _settings;

  InMemorySettingsStorage([UserSettings? initial])
    : _settings = initial ?? const UserSettings();

  @override
  Future<UserSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(UserSettings settings) async {
    _settings = settings;
  }
}

/// File-based implementation of [SettingsStorage] using local JSON storage.
class FileSettingsStorage implements SettingsStorage {
  final File file;

  FileSettingsStorage(this.file);

  @override
  Future<UserSettings> loadSettings() async {
    try {
      if (!await file.exists()) {
        return const UserSettings();
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const UserSettings();
      }
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return UserSettings.fromJson(map);
    } catch (e, stack) {
      AppLogger.warning(
        'FileSettingsStorage',
        'Failed to read settings file, returning defaults: $e',
        stackTrace: stack,
      );
      return const UserSettings();
    }
  }

  @override
  Future<void> saveSettings(UserSettings settings) async {
    try {
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      final jsonStr = jsonEncode(settings.toJson());
      await file.writeAsString(jsonStr, flush: true);
    } catch (e, stack) {
      AppLogger.error(
        'FileSettingsStorage',
        'Failed to persist settings: $e',
        error: e,
        stackTrace: stack,
      );
    }
  }
}
