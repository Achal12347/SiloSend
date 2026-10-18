import 'dart:convert';
import 'dart:io';

import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

/// How a recorded transfer ended.
enum TransferOutcome { completed, failed, cancelled }

/// Coarse reason a transfer did not complete, stored in history.
enum TransferFailureKind {
  connection,
  timeout,
  outOfSpace,
  saveFailed,
  sourceUnreadable,
  corrupted,
  unconfirmed,
  declined,
  notReceiving,
  cancelled,
  other,
}

/// Classifies a transfer error for history.
TransferFailureKind transferFailureKind(Object error) {
  if (error is InsufficientStorageException) {
    return TransferFailureKind.outOfSpace;
  }
  if (error is TransferStorageException) {
    return error.outOfSpace
        ? TransferFailureKind.outOfSpace
        : TransferFailureKind.saveFailed;
  }
  if (error is TransferSourceException) {
    return TransferFailureKind.sourceUnreadable;
  }
  if (error is TransferConnectionException) {
    return TransferFailureKind.connection;
  }
  if (error is TransferTimeoutException) return TransferFailureKind.timeout;
  if (error is TransferChecksumMismatchException) {
    return TransferFailureKind.corrupted;
  }
  if (error is TransferVerificationTimeoutException) {
    return TransferFailureKind.unconfirmed;
  }
  if (error is TransferBatchDeclinedException) {
    return error.reason == TransferCancelReason.notReceiving
        ? TransferFailureKind.notReceiving
        : TransferFailureKind.declined;
  }
  if (error is TransferCancelledException) {
    if (error.reason.contains("isn't receiving")) {
      return TransferFailureKind.notReceiving;
    }
    return error.reason.toLowerCase().contains('declined')
        ? TransferFailureKind.declined
        : TransferFailureKind.cancelled;
  }
  return TransferFailureKind.other;
}

/// One finished file transfer, kept after the app restarts.
///
/// Holds what the user needs to recognise and reopen it. Never file
/// contents, keys or session data.
class TransferHistoryRecord {
  final String transferId;
  final String? batchId;
  final bool outbound;
  final String peerDeviceId;

  /// Peer's name at the time of the transfer (names can change later).
  final String peerName;
  final String fileName;
  final int sizeBytes;
  final String mimeType;
  final bool isContact;
  final TransferOutcome outcome;

  /// Why it failed, as a [TransferFailureKind] name; the UI words it.
  final String? failureKind;
  final DateTime finishedAt;

  /// Receiver only: where the verified file was saved.
  final String? savedPath;

  const TransferHistoryRecord({
    required this.transferId,
    this.batchId,
    required this.outbound,
    required this.peerDeviceId,
    required this.peerName,
    required this.fileName,
    required this.sizeBytes,
    required this.mimeType,
    this.isContact = false,
    required this.outcome,
    this.failureKind,
    required this.finishedAt,
    this.savedPath,
  });

  Map<String, Object?> toJson() => {
    'id': transferId,
    if (batchId != null) 'batch': batchId,
    'out': outbound,
    'peer': peerDeviceId,
    'peerName': peerName,
    'name': fileName,
    'size': sizeBytes,
    'mime': mimeType,
    if (isContact) 'contact': true,
    'outcome': outcome.name,
    if (failureKind != null) 'kind': failureKind,
    'at': finishedAt.toUtc().toIso8601String(),
    if (savedPath != null) 'path': savedPath,
  };

  static TransferHistoryRecord? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      return TransferHistoryRecord(
        transferId: raw['id'] as String,
        batchId: raw['batch'] as String?,
        outbound: raw['out'] as bool,
        peerDeviceId: raw['peer'] as String,
        peerName: raw['peerName'] as String,
        fileName: raw['name'] as String,
        sizeBytes: raw['size'] as int,
        mimeType: raw['mime'] as String,
        isContact: raw['contact'] as bool? ?? false,
        outcome: TransferOutcome.values.byName(raw['outcome'] as String),
        failureKind: raw['kind'] as String?,
        finishedAt: DateTime.parse(raw['at'] as String).toLocal(),
        savedPath: raw['path'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Where history records are kept.
abstract class TransferHistoryStorage {
  Future<List<TransferHistoryRecord>> load();
  Future<void> save(List<TransferHistoryRecord> records);
}

class InMemoryTransferHistoryStorage implements TransferHistoryStorage {
  List<TransferHistoryRecord> _records = const [];

  @override
  Future<List<TransferHistoryRecord>> load() async => List.of(_records);

  @override
  Future<void> save(List<TransferHistoryRecord> records) async {
    _records = List.of(records);
  }
}

/// JSON file in app-private storage, replaced atomically so a crash while
/// saving cannot wipe the history.
class FileTransferHistoryStorage implements TransferHistoryStorage {
  final File file;

  FileTransferHistoryStorage(this.file);

  @override
  Future<List<TransferHistoryRecord>> load() async {
    try {
      if (!await file.exists()) return [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) return [];
      final entries = decoded['transfers'];
      if (entries is! List) return [];
      return [for (final e in entries) ?TransferHistoryRecord.tryFromJson(e)];
    } catch (e) {
      AppLogger.warning('TransferHistory', 'History file unreadable: $e');
      return [];
    }
  }

  @override
  Future<void> save(List<TransferHistoryRecord> records) async {
    final payload = jsonEncode({
      'version': 1,
      'transfers': records.map((r) => r.toJson()).toList(),
    });
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(file.path);
  }
}

/// Newest-first list of finished transfers, capped at [capacity].
class TransferHistory {
  static const int capacity = 500;

  final TransferHistoryStorage storage;
  final List<TransferHistoryRecord> _records = [];
  Future<void> _saving = Future.value();

  TransferHistory(this.storage);

  List<TransferHistoryRecord> get records => List.unmodifiable(_records);

  Future<void> load() async {
    _records
      ..clear()
      ..addAll(await storage.load());
    _records.sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
  }

  /// Adds [record] (replacing an earlier entry for the same transfer).
  Future<void> add(TransferHistoryRecord record) {
    _records.removeWhere((r) => r.transferId == record.transferId);
    _records.insert(0, record);
    if (_records.length > capacity) {
      _records.removeRange(capacity, _records.length);
    }
    return _persist();
  }

  Future<void> remove(String transferId) {
    _records.removeWhere((r) => r.transferId == transferId);
    return _persist();
  }

  Future<void> clear() {
    _records.clear();
    return _persist();
  }

  // Saves run one after another so an older snapshot never overwrites a newer one.
  Future<void> _persist() {
    final snapshot = List<TransferHistoryRecord>.of(_records);
    _saving = _saving.then((_) => storage.save(snapshot)).catchError((
      Object e,
    ) {
      AppLogger.warning('TransferHistory', 'Saving history failed: $e');
    });
    return _saving;
  }
}
