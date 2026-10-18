import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:vayu/core/contracts/storage_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/transfer/payload_destination.dart';

/// Concrete implementation of [StorageService] managing incoming downloads
/// on Android (via `com.achyrio.vayu/storage`) and desktop operating systems.
class SystemStorageService implements StorageService {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/storage',
  );

  final MethodChannel channel;
  final String? customDownloadsDirectory;

  SystemStorageService({MethodChannel? channel, this.customDownloadsDirectory})
    : channel = channel ?? _channel;

  @override
  Future<String> getDownloadsDirectory() async {
    if (customDownloadsDirectory != null) {
      final dir = Directory(customDownloadsDirectory!);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir.path;
    }

    if (Platform.isAndroid) {
      try {
        final path = await channel.invokeMethod<String>(
          'getDownloadsDirectory',
        );
        if (path != null && path.isNotEmpty) {
          final dir = Directory(path);
          if (!dir.existsSync()) {
            dir.createSync(recursive: true);
          }
          return path;
        }
      } on PlatformException catch (e) {
        AppLogger.error(
          'SystemStorageService',
          'Failed to query native downloads directory: ${e.message}',
        );
      }
    }

    // Desktop / Fallback resolution
    final String userHome =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;

    final fallback = Directory('$userHome/Downloads/Vayu');
    if (!fallback.existsSync()) {
      try {
        fallback.createSync(recursive: true);
      } catch (_) {
        // Fallback to temp if Downloads is not writable
        final tempFallback = Directory('${Directory.systemTemp.path}/Vayu');
        if (!tempFallback.existsSync()) {
          tempFallback.createSync(recursive: true);
        }
        return tempFallback.path;
      }
    }
    return fallback.path;
  }

  @override
  Future<String> reserveDestinationPath(
    String baseDirectory,
    String requestedFileName,
  ) async {
    // Strip directory traversal and path segments, extract just the file name
    final segments = requestedFileName
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList();
    var rawName = segments.isEmpty ? 'vayu_file' : segments.last;
    while (rawName.contains('..')) {
      rawName = rawName.replaceAll('..', '');
    }
    final cleanName = rawName.replaceAll(RegExp(r'^\.+'), '');
    final safeName = _fitFileName(cleanName.isEmpty ? 'vayu_file' : cleanName);

    for (var n = 0; ; n++) {
      final candidate = numberedPath('$baseDirectory/$safeName', n);
      if (File(candidate).existsSync()) continue;
      // Creating the staging file exclusively is atomic: a transfer that
      // already holds this name (or a partial kept for resume) makes it fail.
      final staging = File('$candidate${FilePayloadDestination.stagingSuffix}');
      try {
        await staging.create(exclusive: true);
      } on FileSystemException {
        if (staging.existsSync()) continue;
        rethrow;
      }
      // A transfer may have finished under this name in the meantime.
      if (File(candidate).existsSync()) {
        await staging.delete();
        continue;
      }
      return candidate;
    }
  }

  /// File names are limited to 255 bytes on Android and Windows. The staging
  /// suffix and a ` (n)` number must still fit, or the file can never be
  /// created; long names are shortened before the extension.
  static const int _maxNameBytes =
      255 - FilePayloadDestination.stagingSuffix.length - 8;

  static String _fitFileName(String name) {
    if (utf8.encode(name).length <= _maxNameBytes) return name;
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && name.length - dot <= 16 ? name.substring(dot) : '';
    final base = ext.isEmpty ? name : name.substring(0, dot);
    final budget = _maxNameBytes - utf8.encode(ext).length;
    // Shorten by characters so a multi-byte character is never split.
    var cut = base;
    while (utf8.encode(cut).length > budget) {
      cut = String.fromCharCodes(cut.runes.take(cut.runes.length - 1));
    }
    return '$cut$ext';
  }

  @override
  Future<int?> getFreeBytes(String directory) async {
    // dart:io has no free-space API; only Android answers natively.
    if (!Platform.isAndroid) return null;
    try {
      final free = await channel.invokeMethod<int>('getFreeBytes', {
        'path': directory,
      });
      return free;
    } on PlatformException catch (e) {
      AppLogger.warning(
        'SystemStorageService',
        'Free space query failed: ${e.message}',
      );
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> notifyMediaScanner(String filePath) async {
    if (!Platform.isAndroid) return;
    try {
      await channel.invokeMethod('scanCompletedFile', {'path': filePath});
    } on PlatformException catch (e) {
      AppLogger.warning(
        'SystemStorageService',
        'Media scanner notification failed for $filePath: ${e.message}',
      );
    }
  }
}
