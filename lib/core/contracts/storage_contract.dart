/// Abstract contract for managing local and public storage directories,
/// ensuring safe destination paths across different operating systems.
abstract class StorageService {
  /// Returns the default directory path for incoming Vayu transfers
  /// (e.g. public Downloads/Vayu on Android, %USERPROFILE%\Downloads\Vayu on Windows).
  Future<String> getDownloadsDirectory();

  /// Resolves a collision-safe destination file path in [baseDirectory] for [requestedFileName].
  ///
  /// If `file.txt` exists, returns `file (1).txt`, then `file (2).txt`, etc.
  Future<String> resolveUniqueDestinationPath(
    String baseDirectory,
    String requestedFileName,
  );

  /// Free bytes available to this app in [directory], or `null` when the
  /// platform cannot tell (callers must then proceed without a pre-check).
  Future<int?> getFreeBytes(String directory);

  /// Notifies the platform media scanner (on Android) so that newly completed
  /// files appear immediately in user galleries and file managers.
  Future<void> notifyMediaScanner(String filePath);
}
