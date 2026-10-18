import 'package:vayu/core/contracts/transfer_contract.dart';

/// Represents a document selected by the user via platform file selection.
///
/// Decoupled from raw filesystem paths to transparently support Android Storage
/// Access Framework (SAF) content:// URIs, cloud providers, and streams.
class SelectedDocument {
  /// Platform-specific identifier or URI (e.g. content://... on Android, file path on desktop).
  final String identifier;

  /// Display name of the file (e.g. 'document.pdf').
  final String name;

  /// Exact size of the document in bytes, or -1 if unknown.
  final int sizeBytes;

  /// MIME type of the document, if resolved.
  final String? mimeType;

  /// Folder the document sits in when a whole folder is sent, as a
  /// '/'-separated path starting with the picked folder's name
  /// (`Photos/2024`). Null for individually picked files.
  final String? folder;

  const SelectedDocument({
    required this.identifier,
    required this.name,
    required this.sizeBytes,
    this.mimeType,
    this.folder,
  });

  Map<String, dynamic> toJson() => {
    'identifier': identifier,
    'name': name,
    'sizeBytes': sizeBytes,
    'mimeType': mimeType,
    if (folder != null) 'folder': folder,
  };

  @override
  String toString() =>
      'SelectedDocument($name, size: $sizeBytes bytes, mime: $mimeType)';
}

/// Abstract contract for platform document picking and stream creation.
abstract class FilePickerService {
  /// Launches the platform document picker and returns the selected document,
  /// or `null` if the user cancelled.
  Future<SelectedDocument?> pickDocument();

  /// Launches the platform document picker allowing multiple document selection.
  /// Returns an empty list if the user cancelled or none were selected.
  Future<List<SelectedDocument>> pickMultipleDocuments();

  /// Launches the platform folder picker and lists every file inside the
  /// chosen folder and its subfolders. Null if the user cancelled.
  Future<PickedFolder?> pickFolder();

  /// Creates a [PayloadSource] for the given [document], enabling streaming/chunk reads
  /// without copying the document or loading the full content into memory.
  PayloadSource createPayloadSource(SelectedDocument document);
}

/// A folder chosen to be sent whole.
class PickedFolder {
  final String name;

  /// Every file inside, each with its [SelectedDocument.folder] set.
  final List<SelectedDocument> documents;

  /// True when the folder held more files than Vayu lists at once.
  final bool truncated;

  const PickedFolder({
    required this.name,
    required this.documents,
    this.truncated = false,
  });

  int get totalBytes =>
      documents.fold(0, (sum, d) => sum + (d.sizeBytes > 0 ? d.sizeBytes : 0));
}
