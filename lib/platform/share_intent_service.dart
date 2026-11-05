import 'dart:async';

import 'package:flutter/services.dart';

import 'package:vayu/core/contracts/file_picker_contract.dart';

/// Files shared to Vayu from other apps through the Android share sheet,
/// and Receive codes (`vayu://pair` links) opened by another app, usually
/// the phone's own camera after scanning a Receive QR code.
class ShareIntentService {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/share_intent',
  );

  final StreamController<List<SelectedDocument>> _incoming =
      StreamController<List<SelectedDocument>>.broadcast();
  final StreamController<String> _codes = StreamController<String>.broadcast();

  ShareIntentService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShared') {
        final docs = _parse(call.arguments);
        if (docs.isNotEmpty) _incoming.add(docs);
      } else if (call.method == 'onCode' && call.arguments is String) {
        _codes.add(call.arguments as String);
      }
      return null;
    });
  }

  /// Shares that arrive while Vayu is already running.
  Stream<List<SelectedDocument>> get incoming => _incoming.stream;

  /// Receive codes opened while Vayu is already running.
  Stream<String> get codes => _codes.stream;

  /// The Receive code Vayu was launched with, consumed once.
  Future<String?> takePendingCode() async {
    try {
      return await _channel.invokeMethod<String>('takePendingCode');
    } catch (_) {
      return null;
    }
  }

  /// Files Vayu was launched with, consumed once.
  Future<List<SelectedDocument>> takePending() async {
    try {
      return _parse(await _channel.invokeMethod<List<dynamic>>('takePending'));
    } catch (_) {
      return const [];
    }
  }

  static List<SelectedDocument> _parse(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) {
          return SelectedDocument(
            identifier: m['uri'] as String? ?? '',
            name: m['name'] as String? ?? 'shared_file',
            sizeBytes: (m['size'] as num?)?.toInt() ?? -1,
            mimeType: m['mimeType'] as String?,
          );
        })
        .where((d) => d.identifier.isNotEmpty)
        .toList();
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _incoming.close();
    _codes.close();
  }
}
