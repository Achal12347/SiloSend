import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

import '../models/device.dart';
import '../models/transfer_models.dart';
import '../models/transport_models.dart';
import '../services/transfer/p2p_transfer_service.dart';
import '../services/transport/transport_manager.dart';
import 'transfer_repository.dart';

class P2pTransferRepository implements TransferRepository {
  static const int _chunkSize = 12 * 1024;
  static const String _nativeSaveDirectoryName = 'silosend-native-transfers';
  static const String _messageVersion = '1';
  static const String _messageTypeInit = 'transfer_init';
  static const String _messageTypeChunk = 'transfer_chunk';
  static const String _messageTypeComplete = 'transfer_complete';
  static const String _messageTypeCancel = 'transfer_cancel';

  final P2pTransferService _service;
  final SmartTransportManager _transportManager;
  final StreamController<TransferState> _stateController =
      StreamController<TransferState>.broadcast();
  final Map<String, _IncomingTransferSession> _incomingSessions = {};
  final Map<String, _OutgoingTransferSession> _outgoingSessions = {};
  final List<String> _outgoingQueue = [];
  final Map<String, String> _nativeOutgoingFileIds = {};
  final Set<String> _nativeIncomingDownloads = {};

  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<List<HostedFileInfo>>? _sentFilesSubscription;
  StreamSubscription<List<ReceivableFileInfo>>? _receivedFilesSubscription;
  TransferState _state = const TransferState();
  String? _activeOutgoingTransferId;

  P2pTransferRepository({
    required this._service,
    required SmartTransportManager transportManager,
  }) : _transportManager = transportManager {
    _stateController.add(_state);
    _messageSubscription = _service.watchIncomingMessages().listen(
      _handleIncomingMessage,
      onError: _handleTransportError,
    );
    _sentFilesSubscription = _service.watchSentFilesInfo().listen(
      _handleSentFilesUpdate,
      onError: _handleTransportError,
    );
    _receivedFilesSubscription = _service.watchReceivedFilesInfo().listen(
      _handleReceivableFilesUpdate,
      onError: _handleTransportError,
    );
  }

  @override
  TransferState get currentState => _state;

  @override
  Stream<TransferState> watchState() => _stateController.stream;

  @override
  Future<void> queueOutgoingFiles({
    required Device peer,
    required List<TransferSourceFile> files,
  }) async {
    for (final file in files) {
      final decision = await _transportManager.decideForFile(file.size);
      final transferId = _generateTransferId();
      final now = DateTime.now().toUtc();
      final item = TransferItem(
        id: transferId,
        direction: TransferDirection.outgoing,
        transportMode: decision.mode,
        transportReason: decision.reason,
        peerId: peer.id,
        peerName: peer.name,
        fileName: file.name,
        filePath: file.path,
        totalBytes: file.size,
        transferredBytes: 0,
        chunkSize: _chunkSize,
        chunkCount: _chunkCountFor(file.size),
        currentChunkIndex: 0,
        status: TransferStatus.queued,
        checksum: '',
        createdAt: now,
        updatedAt: now,
      );
      _outgoingQueue.add(transferId);
      _outgoingSessions[transferId] = _OutgoingTransferSession(
        sourceFile: file,
        peer: peer,
        transportMode: decision.mode,
        transportReason: decision.reason,
      );
      _updateState((items) => [...items, item]);
    }

    unawaited(_processOutgoingQueue());
  }

  @override
  Future<void> pauseTransfer(String transferId) async {
    final session = _outgoingSessions[transferId];
    if (session == null) return;
    session.isPaused = true;
    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.paused,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
  }

  @override
  Future<void> resumeTransfer(String transferId) async {
    final session = _outgoingSessions[transferId];
    if (session == null) return;
    session.isPaused = false;
    session.resumeCompleter?.complete();
    session.resumeCompleter = null;
    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.transferring,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
    unawaited(_processOutgoingQueue());
  }

  @override
  Future<void> cancelTransfer(String transferId) async {
    final session = _outgoingSessions[transferId];
    if (session != null) {
      session.isCanceled = true;
      session.resumeCompleter?.complete();
      session.resumeCompleter = null;
      _outgoingQueue.remove(transferId);
    }
    final incomingSession = _incomingSessions[transferId];
    if (incomingSession != null) {
      await incomingSession.dispose(deleteFile: true);
      _incomingSessions.remove(transferId);
    }

    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.canceled,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
  }

  @override
  Future<void> retryTransfer(String transferId) async {
    final item = _state.items
        .where((item) => item.id == transferId)
        .firstOrNull;
    if (item == null) return;

    if (item.direction == TransferDirection.outgoing) {
      final session = _outgoingSessions[transferId];
      if (session == null) return;
      session.isCanceled = false;
      session.isPaused = false;
      session.resumeCompleter?.complete();
      session.resumeCompleter = null;
      _updateTransfer(
        transferId,
        (current) => current.copyWith(
          status: TransferStatus.queued,
          transferredBytes: 0,
          currentChunkIndex: 0,
          checksum: '',
          errorMessage: null,
          updatedAt: DateTime.now().toUtc(),
          clearError: true,
        ),
      );
      if (!_outgoingQueue.contains(transferId)) {
        _outgoingQueue.add(transferId);
      }
      unawaited(_processOutgoingQueue());
      return;
    }

    if (item.direction == TransferDirection.incoming &&
        item.savedPath != null) {
      final savedPath = item.savedPath!;
      final file = File(savedPath);
      if (!await file.exists()) {
        return;
      }
      _updateTransfer(
        transferId,
        (current) => current.copyWith(
          status: TransferStatus.completed,
          transferredBytes: current.totalBytes,
          updatedAt: DateTime.now().toUtc(),
          clearError: true,
        ),
      );
    }
  }

  Future<void> _processOutgoingQueue() async {
    if (_activeOutgoingTransferId != null) return;
    final nextTransferId = _outgoingQueue.firstOrNull;
    if (nextTransferId == null) return;

    final session = _outgoingSessions[nextTransferId];
    if (session == null) {
      _outgoingQueue.remove(nextTransferId);
      return;
    }

    _activeOutgoingTransferId = nextTransferId;
    _updateTransfer(
      nextTransferId,
      (item) => item.copyWith(
        status: TransferStatus.preparing,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );

    try {
      await _sendOutgoingTransfer(nextTransferId, session);
    } catch (error) {
      _updateTransfer(
        nextTransferId,
        (item) => item.copyWith(
          status: TransferStatus.failed,
          errorMessage: error.toString(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    } finally {
      _outgoingQueue.remove(nextTransferId);
      _activeOutgoingTransferId = null;
      if (_outgoingQueue.isNotEmpty) {
        unawaited(_processOutgoingQueue());
      }
    }
  }

  Future<void> _sendOutgoingTransfer(
    String transferId,
    _OutgoingTransferSession session,
  ) async {
    if (session.transportMode == TransferTransportMode.nativeFile) {
      await _sendNativeOutgoingTransfer(transferId, session);
      return;
    }

    final sourceFile = File(session.sourceFile.path);
    if (!await sourceFile.exists()) {
      throw StateError('File not found: ${session.sourceFile.path}');
    }

    final totalBytes = await sourceFile.length();
    final digest = await _checksumForFile(sourceFile);
    final chunkCount = _chunkCountFor(totalBytes);

    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.transferring,
        chunkCount: chunkCount,
        checksum: digest,
        totalBytes: totalBytes,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );

    final initMessage = jsonEncode({
      'v': _messageVersion,
      'type': _messageTypeInit,
      'transferId': transferId,
      'fileName': session.sourceFile.name,
      'fileSize': totalBytes,
      'chunkSize': _chunkSize,
      'chunkCount': chunkCount,
      'checksum': digest,
      'peerId': session.peer.id,
      'peerName': session.peer.name,
      'direction': TransferDirection.outgoing.name,
    });
    await _service.sendTextToClient(session.peer.id, initMessage);

    final raf = await sourceFile.open(mode: FileMode.read);
    try {
      var chunkIndex = 0;
      while (chunkIndex < chunkCount) {
        if (session.isCanceled) {
          await _service.sendTextToClient(
            session.peer.id,
            jsonEncode({
              'v': _messageVersion,
              'type': _messageTypeCancel,
              'transferId': transferId,
            }),
          );
          throw StateError('Transfer canceled');
        }

        if (session.isPaused) {
          session.resumeCompleter ??= Completer<void>();
          await session.resumeCompleter!.future;
          continue;
        }

        final chunk = await raf.read(_chunkSize);
        if (chunk.isEmpty) {
          break;
        }

        final chunkMessage = jsonEncode({
          'v': _messageVersion,
          'type': _messageTypeChunk,
          'transferId': transferId,
          'chunkIndex': chunkIndex,
          'chunkCount': chunkCount,
          'data': base64Encode(chunk),
        });
        await _service.sendTextToClient(session.peer.id, chunkMessage);

        final transferredBytes = (chunkIndex * _chunkSize) + chunk.length;
        _updateTransfer(
          transferId,
          (item) => item.copyWith(
            transferredBytes: transferredBytes,
            currentChunkIndex: chunkIndex + 1,
            status: TransferStatus.transferring,
            totalBytes: totalBytes,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        chunkIndex += 1;
      }
    } finally {
      await raf.close();
    }

    if (session.isCanceled) {
      throw StateError('Transfer canceled');
    }

    await _service.sendTextToClient(
      session.peer.id,
      jsonEncode({
        'v': _messageVersion,
        'type': _messageTypeComplete,
        'transferId': transferId,
        'checksum': digest,
        'fileSize': totalBytes,
      }),
    );

    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.completed,
        transferredBytes: totalBytes,
        currentChunkIndex: chunkCount,
        checksum: digest,
        totalBytes: totalBytes,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
  }

  Future<void> _sendNativeOutgoingTransfer(
    String transferId,
    _OutgoingTransferSession session,
  ) async {
    final sourceFile = File(session.sourceFile.path);
    if (!await sourceFile.exists()) {
      throw StateError('File not found: ${session.sourceFile.path}');
    }

    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.transferring,
        transferredBytes: 0,
        totalBytes: session.sourceFile.size,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );

    final fileInfo = await _service.sendFileToClient(
      sourceFile,
      session.peer.id,
    );
    if (fileInfo == null) {
      throw StateError('Native file transfer could not be started.');
    }

    _nativeOutgoingFileIds[transferId] = fileInfo.id;
    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.verifying,
        currentChunkIndex: 1,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
  }

  Future<void> _handleIncomingMessage(String message) async {
    final payload = _decodeMessage(message);
    if (payload == null) return;

    switch (payload['type']) {
      case _messageTypeInit:
        await _handleIncomingInit(payload);
        break;
      case _messageTypeChunk:
        await _handleIncomingChunk(payload);
        break;
      case _messageTypeComplete:
        await _handleIncomingComplete(payload);
        break;
      case _messageTypeCancel:
        await _handleIncomingCancel(payload);
        break;
      default:
        break;
    }
  }

  Future<void> _handleIncomingInit(Map<String, dynamic> payload) async {
    final transferId = payload['transferId']?.toString();
    final fileName = payload['fileName']?.toString();
    final peerId = payload['peerId']?.toString();
    final peerName = payload['peerName']?.toString() ?? 'Nearby device';
    final fileSize = _toInt(payload['fileSize']);
    final chunkSize = _toInt(payload['chunkSize']);
    final chunkCount = _toInt(payload['chunkCount']);
    final checksum = payload['checksum']?.toString() ?? '';
    if (transferId == null ||
        fileName == null ||
        peerId == null ||
        fileSize == null ||
        chunkSize == null ||
        chunkCount == null) {
      return;
    }

    final now = DateTime.now().toUtc();
    final destinationPath = await _buildDestinationPath(fileName, transferId);
    final transferFile = File(destinationPath);
    await transferFile.parent.create(recursive: true);
    if (!await transferFile.exists()) {
      await transferFile.create(recursive: true);
    }

    final session = await _IncomingTransferSession.create(
      file: transferFile,
      totalBytes: fileSize,
      checksum: checksum,
      chunkCount: chunkCount,
      peerId: peerId,
    );
    _incomingSessions[transferId] = session;
    _updateState((items) {
      final nextItems = [...items];
      nextItems.removeWhere((item) => item.id == transferId);
      nextItems.add(
        TransferItem(
          id: transferId,
          direction: TransferDirection.incoming,
          transportMode: TransferTransportMode.chunkedText,
          transportReason: 'Received over the lightweight chunked path.',
          peerId: peerId,
          peerName: peerName,
          fileName: fileName,
          filePath: destinationPath,
          savedPath: destinationPath,
          totalBytes: fileSize,
          transferredBytes: 0,
          chunkSize: chunkSize,
          chunkCount: chunkCount,
          currentChunkIndex: 0,
          status: TransferStatus.receiving,
          checksum: checksum,
          createdAt: now,
          updatedAt: now,
        ),
      );
      return nextItems;
    });
  }

  Future<void> _handleIncomingChunk(Map<String, dynamic> payload) async {
    final transferId = payload['transferId']?.toString();
    final data = payload['data']?.toString();
    final chunkIndex = _toInt(payload['chunkIndex']);
    if (transferId == null || data == null || chunkIndex == null) return;

    final session = _incomingSessions[transferId];
    if (session == null) return;

    final chunk = base64Decode(data);
    await session.writeChunk(chunkIndex, chunk);
    final receivedBytes = session.receivedBytes;
    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.receiving,
        transferredBytes: receivedBytes,
        currentChunkIndex: chunkIndex + 1,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
  }

  Future<void> _handleIncomingComplete(Map<String, dynamic> payload) async {
    final transferId = payload['transferId']?.toString();
    if (transferId == null) return;

    final session = _incomingSessions[transferId];
    if (session == null) return;

    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.verifying,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );

    await session.finish();
    final computedChecksum = await _checksumForFile(session.file);
    final isValid = computedChecksum == session.checksum;
    if (!isValid) {
      _updateTransfer(
        transferId,
        (item) => item.copyWith(
          status: TransferStatus.failed,
          errorMessage: 'Checksum mismatch',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      return;
    }

    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.completed,
        transferredBytes: item.totalBytes,
        currentChunkIndex: item.chunkCount,
        savedPath: session.file.path,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
    _incomingSessions.remove(transferId);
  }

  Future<void> _handleIncomingCancel(Map<String, dynamic> payload) async {
    final transferId = payload['transferId']?.toString();
    if (transferId == null) return;

    final session = _incomingSessions.remove(transferId);
    if (session != null) {
      await session.dispose(deleteFile: true);
    }
    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.canceled,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
  }

  Future<void> _handleSentFilesUpdate(List<HostedFileInfo> files) async {
    for (final file in files) {
      final fileId = file.info.id;
      final transferId = _nativeOutgoingTransferIdFor(fileId);
      if (transferId == null) {
        continue;
      }

      final progress = _nativeProgressPercent(file);
      final itemState = _nativeFileStateLabel(file.state);
      final isComplete = itemState == 'completed';
      if (isComplete) {
        _nativeOutgoingFileIds.remove(transferId);
      }
      _updateTransfer(
        transferId,
        (item) => item.copyWith(
          status: isComplete
              ? TransferStatus.completed
              : TransferStatus.transferring,
          transferredBytes: (item.totalBytes * progress).round(),
          currentChunkIndex: isComplete ? 1 : 0,
          updatedAt: DateTime.now().toUtc(),
          clearError: true,
        ),
      );
    }
  }

  Future<void> _handleReceivableFilesUpdate(
    List<ReceivableFileInfo> files,
  ) async {
    for (final file in files) {
      final fileId = file.info.id;
      final existingTransfer = _state.items.firstWhereOrNull(
        (item) =>
            item.direction == TransferDirection.incoming && item.id == fileId,
      );
      if (existingTransfer == null) {
        await _registerNativeIncomingTransfer(file);
      } else {
        await _updateNativeIncomingTransfer(file, existingTransfer);
      }
    }
  }

  Future<void> _registerNativeIncomingTransfer(ReceivableFileInfo file) async {
    final fileId = file.info.id;
    if (_nativeIncomingDownloads.contains(fileId)) {
      return;
    }

    final now = DateTime.now().toUtc();
    final saveDirectory = await _nativeSaveDirectory();
    final path = '${saveDirectory.path}/${file.info.name}';
    final totalBytes = file.info.size;
    _nativeIncomingDownloads.add(fileId);

    _updateState((items) {
      final nextItems = [...items];
      nextItems.removeWhere((item) => item.id == fileId);
      nextItems.add(
        TransferItem(
          id: fileId,
          direction: TransferDirection.incoming,
          transportMode: TransferTransportMode.nativeFile,
          transportReason: 'Auto-selected native Wi-Fi file transfer.',
          peerId: file.info.senderId,
          peerName: file.info.senderId,
          fileName: file.info.name,
          filePath: path,
          savedPath: path,
          totalBytes: totalBytes,
          transferredBytes: 0,
          chunkSize: _chunkSize,
          chunkCount: 1,
          currentChunkIndex: 0,
          status: TransferStatus.receiving,
          checksum: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
      return nextItems;
    });

    unawaited(
      _service.downloadFile(
        fileId,
        saveDirectory.path,
        customFileName: file.info.name,
        onProgress: (progress) {
          final bytesDownloaded =
              (progress.bytesDownloaded as num?)?.toInt() ?? 0;
          _updateTransfer(
            fileId,
            (item) => item.copyWith(
              status: TransferStatus.receiving,
              transferredBytes: bytesDownloaded,
              updatedAt: DateTime.now().toUtc(),
              clearError: true,
            ),
          );
        },
      ),
    );
  }

  Future<void> _updateNativeIncomingTransfer(
    ReceivableFileInfo file,
    TransferItem existingTransfer,
  ) async {
    final progress = _nativeProgressPercent(file as HostedFileInfo);
    final stateLabel = _nativeFileStateLabel(file.state);
    final isComplete = stateLabel == 'completed';
    if (isComplete) {
      _nativeIncomingDownloads.remove(file.info.id);
    }

    _updateTransfer(
      existingTransfer.id,
      (item) => item.copyWith(
        status: isComplete
            ? TransferStatus.completed
            : TransferStatus.receiving,
        transferredBytes: (item.totalBytes * progress).round(),
        currentChunkIndex: isComplete ? 1 : 0,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
  }

  void _handleTransportError(Object error, StackTrace stackTrace) {
    _updateState((items) => items, errorMessage: error.toString());
  }

  void _updateTransfer(
    String transferId,
    TransferItem Function(TransferItem item) updater,
  ) {
    _updateState((items) {
      return items
          .map((item) {
            if (item.id != transferId) return item;
            return updater(item);
          })
          .toList(growable: false);
    });
  }

  void _updateState(
    List<TransferItem> Function(List<TransferItem>) updater, {
    String? errorMessage,
  }) {
    _state = _state.copyWith(
      items: updater(_state.items),
      errorMessage: errorMessage,
      clearError: errorMessage == null,
      activeTransferId: _activeOutgoingTransferId,
    );
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  Map<String, dynamic>? _decodeMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic> &&
          decoded['v']?.toString() == _messageVersion) {
        return decoded;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  int? _toInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  int _chunkCountFor(int byteLength) {
    if (byteLength <= 0) return 0;
    return (byteLength / _chunkSize).ceil();
  }

  String _generateTransferId() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  Future<String> _buildDestinationPath(
    String fileName,
    String transferId,
  ) async {
    final directory = Directory(
      '${Directory.systemTemp.path}/silosend-transfers',
    );
    await directory.create(recursive: true);
    final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '${directory.path}/${transferId}_$safeName';
  }

  Future<Directory> _nativeSaveDirectory() async {
    final directory = Directory(
      '${Directory.systemTemp.path}/$_nativeSaveDirectoryName',
    );
    await directory.create(recursive: true);
    return directory;
  }

  String? _nativeOutgoingTransferIdFor(String fileId) {
    for (final entry in _nativeOutgoingFileIds.entries) {
      if (entry.value == fileId) {
        return entry.key;
      }
    }
    return null;
  }

  double _nativeProgressPercent(HostedFileInfo file) {
    if (file.receiverIds.isEmpty) {
      return 0;
    }
    final receiverId = file.receiverIds.first;
    return file.getProgressPercent(receiverId).clamp(0.0, 1.0);
  }

  String _nativeFileStateLabel(Object state) {
    final raw = state.toString().toLowerCase();
    if (raw.contains('completed')) return 'completed';
    if (raw.contains('downloading')) return 'downloading';
    if (raw.contains('idle')) return 'idle';
    if (raw.contains('failed') || raw.contains('error')) return 'failed';
    return raw;
  }

  Future<String> _checksumForFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  @override
  void dispose() {
    unawaited(_messageSubscription?.cancel());
    unawaited(_sentFilesSubscription?.cancel());
    unawaited(_receivedFilesSubscription?.cancel());
    for (final session in _incomingSessions.values) {
      unawaited(session.dispose(deleteFile: false));
    }
    for (final session in _outgoingSessions.values) {
      session.resumeCompleter?.complete();
    }
    _incomingSessions.clear();
    _outgoingSessions.clear();
    _nativeOutgoingFileIds.clear();
    _nativeIncomingDownloads.clear();
    _stateController.close();
  }
}

class _OutgoingTransferSession {
  final TransferSourceFile sourceFile;
  final Device peer;
  final TransferTransportMode transportMode;
  final String transportReason;
  bool isPaused = false;
  bool isCanceled = false;
  Completer<void>? resumeCompleter;

  _OutgoingTransferSession({
    required this.sourceFile,
    required this.peer,
    required this.transportMode,
    required this.transportReason,
  });
}

class _IncomingTransferSession {
  final File file;
  final int totalBytes;
  final String checksum;
  final int chunkCount;
  final String peerId;
  int _receivedBytes = 0;
  late final RandomAccessFile _raf;

  _IncomingTransferSession._({
    required this.file,
    required this.totalBytes,
    required this.checksum,
    required this.chunkCount,
    required this.peerId,
  });

  static Future<_IncomingTransferSession> create({
    required File file,
    required int totalBytes,
    required String checksum,
    required int chunkCount,
    required String peerId,
  }) async {
    final session = _IncomingTransferSession._(
      file: file,
      totalBytes: totalBytes,
      checksum: checksum,
      chunkCount: chunkCount,
      peerId: peerId,
    );
    session._raf = await file.open(mode: FileMode.write);
    return session;
  }

  int get receivedBytes => _receivedBytes;

  Future<void> writeChunk(int chunkIndex, Uint8List chunk) async {
    final position = chunkIndex * 12 * 1024;
    await _raf.setPosition(position);
    await _raf.writeFrom(chunk);
    final endPosition = position + chunk.length;
    if (endPosition > _receivedBytes) {
      _receivedBytes = endPosition;
    }
  }

  Future<void> finish() async {
    await _raf.flush();
    await _raf.close();
  }

  Future<void> dispose({required bool deleteFile}) async {
    try {
      await _raf.close();
    } catch (_) {}
    if (deleteFile) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }
}
