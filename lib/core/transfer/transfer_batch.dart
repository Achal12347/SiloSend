import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/domain/models/transfer_models.dart';

/// Where a batch as a whole stands.
enum TransferBatchState {
  /// Sender: the batch offer is out, waiting for the receiver's one answer.
  awaitingConsent,
  transferring,
  completed,

  /// Finished, but at least one file failed; those can be retried.
  completedWithFailures,

  /// The receiver refused the whole batch.
  declined,

  /// The batch could not run at all (for example the connection failed).
  failed,
}

/// Several files moving between this device and one peer as one unit: one
/// consent, one progress figure, per-file results.
///
/// Built and updated only by [FileSharingCoordinator]; the UI reads it.
class TransferBatch {
  final String batchId;
  final String peerDeviceId;
  final bool outbound;

  /// File names and sizes in batch order.
  final List<String> fileNames;
  final List<int> fileSizes;

  /// Sender only: the documents, kept so failed files can be resent.
  final List<SelectedDocument> documents;

  /// Sender only: true when the receiver was asked once for the whole batch
  /// (its build supports it); false when each file is offered on its own.
  final bool offeredAsBatch;

  /// Receiver only: the folder each file is saved in, from the consented
  /// manifest (null entries are saved directly in the save folder).
  final List<String?> folders;

  TransferBatchState state;

  /// Latest task per file index (a retry replaces the failed one).
  final Map<int, TransferTask> tasks = {};

  /// Why a file failed, per index. Cleared when the file is retried.
  final Map<int, Object> failures = {};

  /// Set when the whole batch was refused or could not start.
  Object? error;

  final DateTime createdAt = DateTime.now();

  TransferBatch({
    required this.batchId,
    required this.peerDeviceId,
    required this.outbound,
    required this.fileNames,
    required this.fileSizes,
    this.documents = const [],
    this.offeredAsBatch = false,
    this.folders = const [],
    this.state = TransferBatchState.transferring,
  });

  /// The folder file [index] is saved in, if it came as part of a folder.
  String? folderOf(int index) =>
      index >= 0 && index < folders.length ? folders[index] : null;

  int get fileCount => fileNames.length;

  int get totalBytes => fileSizes.fold(0, (sum, s) => sum + (s > 0 ? s : 0));

  int get completedCount =>
      tasks.values.where((t) => t.status == TransferStatus.completed).length;

  int get failedCount => failures.length;

  /// Bytes confirmed so far across all files: finished files count in full,
  /// the moving file counts what the engine reports.
  int bytesDone(TransferProgress? Function(TransferTask) progressOf) {
    var done = 0;
    for (final entry in tasks.entries) {
      final task = entry.value;
      if (task.status == TransferStatus.completed) {
        done += fileSizes[entry.key];
      } else if (!failures.containsKey(entry.key)) {
        done += progressOf(task)?.bytesTransferred ?? 0;
      }
    }
    return done;
  }

  /// Index of [transferId] in this batch, or null.
  int? indexOf(String transferId) {
    for (final entry in tasks.entries) {
      if (entry.value.transferId == transferId) return entry.key;
    }
    return null;
  }

  bool get isFinished =>
      state == TransferBatchState.completed ||
      state == TransferBatchState.completedWithFailures ||
      state == TransferBatchState.declined ||
      state == TransferBatchState.failed;
}
