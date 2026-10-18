import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

DateTime? _lastNotice;

/// Catches errors nothing else handled and logs them locally (nothing leaves
/// the phone). A screen that fails to draw also shows one calm notice;
/// background errors stay silent. Debug builds still print the full error.
void installErrorHandlers() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (kDebugMode) {
      previous?.call(details);
    }
    AppLogger.error(
      'Unhandled',
      'Flutter error: ${details.exceptionAsString()}',
      stackTrace: details.stack,
    );
    _notify();
  };
  // Background errors (a radio event, a dropped socket) are logged only: the
  // user did not ask for anything, so a "Something went wrong" notice would
  // be an unwanted popup. Actions the user starts report their own errors.
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.error('Unhandled', 'Uncaught error: $error', stackTrace: stack);
    return true;
  };
  if (!kDebugMode) {
    // A widget that fails to build shows nothing rather than a grey box.
    ErrorWidget.builder = (_) => const SizedBox.shrink();
  }
}

// At most one notice every few seconds, even if errors repeat.
void _notify() {
  final now = DateTime.now();
  final last = _lastNotice;
  if (last != null && now.difference(last) < const Duration(seconds: 5)) {
    return;
  }
  _lastNotice = now;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    showVayuNotice(
      null,
      'Something went wrong. Please try that again.',
      tone: VayuNoticeTone.problem,
    );
  });
}
