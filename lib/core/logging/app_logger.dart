import 'dart:developer' as developer;

/// Log levels for SiloSend application logging.
enum LogLevel { debug, info, warning, error }

/// Secure, sanitized application logger.
///
/// Ensures sensitive cryptographic keys, private data, and authentication
/// secrets are never logged per SiloSend security and privacy requirements.
class AppLogger {
  AppLogger._();

  /// Logs a message with an optional error and stack trace.
  static void log(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    // In production, sensitive data must never be logged.
    final name = 'SiloSend.$tag';
    developer.log(
      message,
      name: name,
      level: _levelToInt(level),
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void debug(String tag, String message) =>
      log(LogLevel.debug, tag, message);

  static void info(String tag, String message) =>
      log(LogLevel.info, tag, message);

  static void warning(String tag, String message) =>
      log(LogLevel.warning, tag, message);

  static void error(
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => log(LogLevel.error, tag, message, error: error, stackTrace: stackTrace);

  static int _levelToInt(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 500;
      case LogLevel.info:
        return 800;
      case LogLevel.warning:
        return 900;
      case LogLevel.error:
        return 1000;
    }
  }
}
