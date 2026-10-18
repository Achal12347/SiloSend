/// Abstract contract for managing local and public storage directories,
/// ensuring safe destination paths across different operating systems.
abstract class StorageService {
  /// Returns the default directory path for incoming Vayu transfers
  /// (e.g. public Downloads/Vayu on Android, %USERPROFILE%\Downloads\Vayu on Windows).
  Future<String> getDownloadsDirectory();

  /// Reserves a destination for one incoming file in [baseDirectory] and
  /// returns its path.
  ///
  /// The name is sanitized; if `file.txt` exists or another transfer holds
  /// it, `file (1).txt`, `file (2).txt`, … is used. The reservation is the
  /// transfer's own staging file (`<path>.vayu.tmp`), created exclusively so
  /// two transfers can never get the same path. The caller owns that file and
  /// must delete it if the transfer never starts.
  Future<String> reserveDestinationPath(
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
