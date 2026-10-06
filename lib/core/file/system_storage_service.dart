import 'dart:io';

import 'package:flutter/services.dart';
import 'package:silosend_datasharing_app/core/contracts/storage_contract.dart';
import 'package:silosend_datasharing_app/core/logging/app_logger.dart';

/// Concrete implementation of [StorageService] managing incoming downloads
/// on Android (via `com.silosend/storage`) and desktop operating systems.
class SystemStorageService implements StorageService {
  static const MethodChannel _channel = MethodChannel('com.silosend/storage');

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

    final fallback = Directory('$userHome/Downloads/SiloSend');
    if (!fallback.existsSync()) {
      try {
        fallback.createSync(recursive: true);
      } catch (_) {
        // Fallback to temp if Downloads is not writable
        final tempFallback = Directory('${Directory.systemTemp.path}/SiloSend');
        if (!tempFallback.existsSync()) {
          tempFallback.createSync(recursive: true);
        }
        return tempFallback.path;
      }
    }
    return fallback.path;
  }

  @override
  Future<String> resolveUniqueDestinationPath(
    String baseDirectory,
    String requestedFileName,
  ) async {
    // Strip directory traversal and path segments, extract just the file name
    final segments = requestedFileName
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList();
    var rawName = segments.isEmpty ? 'silosend_file' : segments.last;
    while (rawName.contains('..')) {
      rawName = rawName.replaceAll('..', '');
    }
    final cleanName = rawName.replaceAll(RegExp(r'^\.+'), '');
    final safeName = cleanName.isEmpty ? 'silosend_file' : cleanName;

    final dotIndex = safeName.lastIndexOf('.');
    final String base;
    final String ext;

    if (dotIndex > 0) {
      base = safeName.substring(0, dotIndex);
      ext = safeName.substring(dotIndex);
    } else {
      base = safeName;
      ext = '';
    }

    // Check if original name is available
    final initialPath = '$baseDirectory/$base$ext';
    if (!File(initialPath).existsSync()) {
      return initialPath;
    }

    // Disambiguate with (1), (2), ...
    int counter = 1;
    while (true) {
      final candidate = '$baseDirectory/$base ($counter)$ext';
      if (!File(candidate).existsSync()) {
        return candidate;
      }
      counter++;
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
