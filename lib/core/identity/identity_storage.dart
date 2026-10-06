import 'dart:convert';
import 'dart:io';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

/// Abstract persistence contract for storing and restoring local device identity.
abstract class IdentityStorage {
  /// Loads the stored [LocalDeviceIdentity], or returns null if none exists.
  Future<LocalDeviceIdentity?> loadIdentity();

  /// Persists the given [LocalDeviceIdentity].
  Future<void> saveIdentity(LocalDeviceIdentity identity);

  /// Clears any persisted identity.
  Future<void> clearIdentity();
}

/// In-memory implementation of [IdentityStorage] used primarily for unit tests.
class InMemoryIdentityStorage implements IdentityStorage {
  LocalDeviceIdentity? _identity;

  InMemoryIdentityStorage([this._identity]);

  @override
  Future<LocalDeviceIdentity?> loadIdentity() async => _identity;

  @override
  Future<void> saveIdentity(LocalDeviceIdentity identity) async {
    _identity = identity;
  }

  @override
  Future<void> clearIdentity() async {
    _identity = null;
  }
}

/// Pure Dart file-based implementation of [IdentityStorage].
///
/// Stores identity profile JSON safely in local application storage.
class FileIdentityStorage implements IdentityStorage {
  final File file;

  FileIdentityStorage(this.file);

  @override
  Future<LocalDeviceIdentity?> loadIdentity() async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final contents = await file.readAsString();
      if (contents.trim().isEmpty) {
        return null;
      }
      final json = jsonDecode(contents) as Map<String, dynamic>;
      return LocalDeviceIdentity.fromJson(json);
    } catch (e, stack) {
      AppLogger.error(
        'FileIdentityStorage',
        'Failed to load device identity from file',
        error: e,
        stackTrace: stack,
      );
      return null;
    }
  }

  @override
  Future<void> saveIdentity(LocalDeviceIdentity identity) async {
    try {
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      final jsonStr = jsonEncode(identity.toJson());
      // Atomic write pattern: write to temp file then rename
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(jsonStr, flush: true);
      await tempFile.rename(file.path);
    } catch (e, stack) {
      AppLogger.error(
        'FileIdentityStorage',
        'Failed to save device identity to file',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  @override
  Future<void> clearIdentity() async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e, stack) {
      AppLogger.error(
        'FileIdentityStorage',
        'Failed to clear device identity file',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }
}
