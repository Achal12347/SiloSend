import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/app/app.dart';
import 'package:silosend/core/logging/app_logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runZonedGuarded(
    () {
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        AppLogger.error(
          'Flutter framework error',
          error: details.exception,
          stackTrace: details.stack,
        );
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        AppLogger.error(
          'Unhandled platform error',
          error: error,
          stackTrace: stack,
        );
        return true;
      };

      runApp(const ProviderScope(child: App()));
    },
    (error, stack) {
      AppLogger.error('Unhandled zone error', error: error, stackTrace: stack);
    },
  );
}
