import 'package:vayu/core/constants/app_constants.dart';

/// Where this app keeps its private files.
///
/// Android passes the real `filesDir` as a launch argument (see
/// `MainActivity.getDartEntrypointArgs`). The fixed `/data/user/0/...` path
/// used before is wrong for a second Android user or a work profile, where
/// writes there fail.
class AppPaths {
  AppPaths._();

  static const String _filesDirArg = '--files-dir=';
  static String? _androidFilesDir;

  /// Reads the launch arguments once at startup.
  static void configureFromArgs(List<String> args) {
    for (final arg in args) {
      if (arg.startsWith(_filesDirArg)) {
        final value = arg.substring(_filesDirArg.length);
        if (value.isNotEmpty) _androidFilesDir = value;
      }
    }
  }

  /// The app's private files folder on Android.
  static String get androidFilesDir =>
      _androidFilesDir ?? '/data/user/0/${AppConstants.applicationId}/files';
}
