/// Abstract contract for managing local and public storage directories,
/// ensuring safe destination paths across different operating systems.
abstract class StorageService {
  /// Returns the default directory path for incoming SiloSend transfers
  /// (e.g. public Downloads/SiloSend on Android, %USERPROFILE%\Downloads\SiloSend on Windows).
  Future<String> getDownloadsDirectory();

  /// Resolves a collision-safe destination file path in [baseDirectory] for [requestedFileName].
  ///
  /// If `file.txt` exists, returns `file (1).txt`, then `file (2).txt`, etc.
  Future<String> resolveUniqueDestinationPath(
    String baseDirectory,
    String requestedFileName,
  );

  /// Notifies the platform media scanner (on Android) so that newly completed
  /// files appear immediately in user galleries and file managers.
  Future<void> notifyMediaScanner(String filePath);
}
