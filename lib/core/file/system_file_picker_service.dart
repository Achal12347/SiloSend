import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/transfer/content_uri_payload_source.dart';
import 'package:vayu/domain/transfer/payload_source.dart';

/// Concrete implementation of [FilePickerService] interacting with the native Android
/// Storage Access Framework (SAF) via platform channel `com.achyrio.vayu/file_picker`.
///
/// Falls back to direct file selection on desktop platforms or during automated tests.
class SystemFilePickerService implements FilePickerService {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/file_picker',
  );

  final MethodChannel channel;
  final Future<SelectedDocument?> Function()? testPickerHandler;
  final Future<List<SelectedDocument>> Function()? testMultiPickerHandler;

  SystemFilePickerService({
    MethodChannel? channel,
    this.testPickerHandler,
    this.testMultiPickerHandler,
  }) : channel = channel ?? _channel;

  @override
  Future<SelectedDocument?> pickDocument() async {
    if (testPickerHandler != null) {
      return testPickerHandler!();
    }

    if (!Platform.isAndroid) {
      AppLogger.info(
        'SystemFilePickerService',
        'Non-Android platform: native SAF picker unavailable; returning null',
      );
      return null;
    }

    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'pickDocument',
      );
      if (result == null) return null;

      final uri = result['uri'] as String? ?? '';
      final name = result['name'] as String? ?? 'selected_document';
      final size = (result['size'] as num?)?.toInt() ?? -1;
      final mime = result['mimeType'] as String?;

      return SelectedDocument(
        identifier: uri,
        name: name,
        sizeBytes: size,
        mimeType: mime,
      );
    } on PlatformException catch (e) {
      AppLogger.error(
        'SystemFilePickerService',
        'Failed to pick document: ${e.message}',
      );
      return null;
    }
  }

  @override
  Future<List<SelectedDocument>> pickMultipleDocuments() async {
    if (testMultiPickerHandler != null) {
      return testMultiPickerHandler!();
    }
    if (testPickerHandler != null) {
      final doc = await testPickerHandler!();
      return doc != null ? [doc] : [];
    }

    if (!Platform.isAndroid) {
      AppLogger.info(
        'SystemFilePickerService',
        'Non-Android platform: native SAF picker unavailable; returning empty list',
      );
      return [];
    }

    try {
      final result = await channel.invokeListMethod<Map<dynamic, dynamic>>(
        'pickMultipleDocuments',
      );
      if (result == null || result.isEmpty) return [];

      return result.map((m) {
        final uri = m['uri'] as String? ?? '';
        final name = m['name'] as String? ?? 'selected_document';
        final size = (m['size'] as num?)?.toInt() ?? -1;
        final mime = m['mimeType'] as String?;
        return SelectedDocument(
          identifier: uri,
          name: name,
          sizeBytes: size,
          mimeType: mime,
        );
      }).toList();
    } on PlatformException catch (e) {
      AppLogger.error(
        'SystemFilePickerService',
        'Failed to pick multiple documents: ${e.message}',
      );
      return [];
    }
  }

  @override
  PayloadSource createPayloadSource(SelectedDocument document) {
    // If identifier starts with content://, use ContentUriPayloadSource
    if (document.identifier.startsWith('content://')) {
      return ContentUriPayloadSource(
        uri: document.identifier,
        length: document.sizeBytes,
        readChunkCallback: (uri, offset, length) async {
          final result = await channel.invokeMethod<Uint8List>('readChunk', {
            'uri': uri,
            'offset': offset,
            'length': length,
          });
          return result ?? Uint8List(0);
        },
        closeCallback: (uri) async {
          await channel.invokeMethod('closeFile', {'uri': uri});
        },
      );
    }

    // Direct filesystem path fallback
    final file = File(document.identifier);
    if (file.existsSync()) {
      return FilePayloadSource(file);
    }

    // Default fallback to content URI source
    return ContentUriPayloadSource(
      uri: document.identifier,
      length: document.sizeBytes,
      readChunkCallback: (uri, offset, length) async {
        final result = await channel.invokeMethod<Uint8List>('readChunk', {
          'uri': uri,
          'offset': offset,
          'length': length,
        });
        return result ?? Uint8List(0);
      },
      closeCallback: (uri) async {
        await channel.invokeMethod('closeFile', {'uri': uri});
      },
    );
  }
}
