import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

import '../models/device.dart';
import '../models/transfer_models.dart';
import '../models/transport_models.dart';
import '../services/encryption/encryption_service.dart';
import '../services/encryption/key_exchange.dart';
import '../services/transfer/p2p_transfer_service.dart';
import '../services/transport/transport_manager.dart';
import 'transfer_repository.dart';

class P2pTransferRepository implements TransferRepository {
  static const int _chunkSize = 12 * 1024;
  static const String _nativeSaveDirectoryName = 'silosend-native-transfers';
  static const String _messageVersion = '1';
  static const String _messageEncryptionVersion = 'aes-gcm-1';
  static const String _messageTypeInit = 'transfer_init';
  static const String _messageTypeChunk = 'transfer_chunk';
  static const String _messageTypeComplete = 'transfer_complete';
  static const String _messageTypeCancel = 'transfer_cancel';
  static const String _nativeEncryptedSuffix = '.siloenc';

  final P2pTransferService _service;
  final SmartTransportManager transportManager;
  final EncryptionService _encryptionService = EncryptionService();
  final KeyExchange _keyExchange = KeyExchange();
  final StreamController<TransferState> _stateController =
      StreamController<TransferState>.broadcast();
  final Map<String, _IncomingTransferSession> _incomingSessions = {};
  final Map<String, _OutgoingTransferSession> _outgoingSessions = {};
  final Map<String, _TransferSecuritySession> _securitySessions = {};
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
    required this.transportManager,
  }) {
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
      final decision = await transportManager.decideForFile(file.size);
      final transferId = _generateTransferId();
      final sessionKeyBytes = _keyExchange.generateSessionKey();
      final secretKey = _encryptionService.keyFromBytes(sessionKeyBytes);
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
        sessionKeyBytes: sessionKeyBytes,
        secretKey: secretKey,
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
      'encrypted': true,
      'encryptionVersion': _messageEncryptionVersion,
      'sessionKey': base64Encode(session.sessionKeyBytes),
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

        final encrypted = await _encryptChunk(
          transferId: transferId,
          chunkIndex: chunkIndex,
          plaintext: Uint8List.fromList(chunk),
          secretKey: session.secretKey,
        );
        final chunkMessage = jsonEncode({
          'v': _messageVersion,
          'type': _messageTypeChunk,
          'transferId': transferId,
          'chunkIndex': chunkIndex,
          'chunkCount': chunkCount,
          'encrypted': true,
          'cipherText': base64Encode(encrypted.cipherText),
          'mac': base64Encode(encrypted.mac.bytes),
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
        'encrypted': true,
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

    final totalBytes = await sourceFile.length();
    final digest = await _checksumForFile(sourceFile);
    final chunkCount = _chunkCountFor(totalBytes);
    final encryptedPackage = await _buildEncryptedNativePackage(
      transferId: transferId,
      sourceFile: sourceFile,
      session: session,
      totalBytes: totalBytes,
      digest: digest,
      chunkCount: chunkCount,
    );

    _updateTransfer(
      transferId,
      (item) => item.copyWith(
        status: TransferStatus.transferring,
        transferredBytes: 0,
        totalBytes: totalBytes,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );

    final fileInfo = await _service.sendFileToClient(
      encryptedPackage,
      session.peer.id,
    );
    if (fileInfo == null) {
      throw StateError('Native file transfer could not be started.');
    }

    _nativeOutgoingFileIds[transferId] = fileInfo.id;
    await _service.sendTextToClient(
      session.peer.id,
      jsonEncode({
        'v': _messageVersion,
        'type': _messageTypeInit,
        'transferId': transferId,
        'nativeFileId': fileInfo.id,
        'fileName': session.sourceFile.name,
        'encryptedFileName': encryptedPackage.path
            .split(Platform.pathSeparator)
            .last,
        'fileSize': totalBytes,
        'chunkSize': _chunkSize,
        'chunkCount': chunkCount,
        'checksum': digest,
        'peerId': session.peer.id,
        'peerName': session.peer.name,
        'direction': TransferDirection.outgoing.name,
        'encrypted': true,
        'encryptionVersion': _messageEncryptionVersion,
        'sessionKey': base64Encode(session.sessionKeyBytes),
        'transportMode': TransferTransportMode.nativeFile.name,
      }),
    );

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

  Future<File> _buildEncryptedNativePackage({
    required String transferId,
    required File sourceFile,
    required _OutgoingTransferSession session,
    required int totalBytes,
    required String digest,
    required int chunkCount,
  }) async {
    final directory = Directory(
      '${Directory.systemTemp.path}/silosend-encrypted-native',
    );
    await directory.create(recursive: true);
    final safeName = session.sourceFile.name.replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '_',
    );
    final encryptedFileName =
        [transferId, safeName].join('_') + _nativeEncryptedSuffix;
    final encryptedFile = File('${directory.path}/$encryptedFileName');
    await encryptedFile.parent.create(recursive: true);

    final sink = encryptedFile.openWrite();
    try {
      sink.writeln(
        jsonEncode({
          'v': _messageVersion,
          'type': 'encrypted_native_package',
          'transferId': transferId,
          'fileName': session.sourceFile.name,
          'fileSize': totalBytes,
          'chunkSize': _chunkSize,
          'chunkCount': chunkCount,
          'checksum': digest,
          'encryptionVersion': _messageEncryptionVersion,
        }),
      );

      final raf = await sourceFile.open(mode: FileMode.read);
      try {
        var chunkIndex = 0;
        while (true) {
          final chunk = await raf.read(_chunkSize);
          if (chunk.isEmpty) break;

          final encrypted = await _encryptChunk(
            transferId: transferId,
            chunkIndex: chunkIndex,
            plaintext: Uint8List.fromList(chunk),
            secretKey: session.secretKey,
          );
          sink.writeln(
            jsonEncode({
              'chunkIndex': chunkIndex,
              'cipherText': base64Encode(encrypted.cipherText),
              'mac': base64Encode(encrypted.mac.bytes),
            }),
          );
          chunkIndex += 1;
        }
      } finally {
        await raf.close();
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    return encryptedFile;
  }

  Future<SecretBox> _encryptChunk({
    required String transferId,
    required int chunkIndex,
    required Uint8List plaintext,
    required SecretKey secretKey,
  }) async {
    final nonce = await _encryptionService.generateNonce(
      transferId: transferId,
      chunkIndex: chunkIndex,
    );
    return _encryptionService.encryptBytes(
      plaintext: plaintext,
      key: secretKey,
      nonce: nonce,
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
    final sessionKey = payload['sessionKey']?.toString();
    final nativeFileId = payload['nativeFileId']?.toString();
    if (transferId == null ||
        fileName == null ||
        peerId == null ||
        fileSize == null ||
        chunkSize == null ||
        chunkCount == null ||
        sessionKey == null) {
      return;
    }

    final secretKey = _encryptionService.keyFromBytes(
      Uint8List.fromList(base64Decode(sessionKey)),
    );
    final now = DateTime.now().toUtc();
    String? destinationPath;
    if (nativeFileId != null && nativeFileId.isNotEmpty) {
      _securitySessions[nativeFileId] = _TransferSecuritySession(
        keyId: nativeFileId,
        transferId: transferId,
        transportMode: TransferTransportMode.nativeFile,
        secretKey: secretKey,
        checksum: checksum,
      );
      return;
    } else {
      destinationPath = await _buildDestinationPath(fileName, transferId);
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
        secretKey: secretKey,
      );
      _incomingSessions[transferId] = session;
      _securitySessions[transferId] = _TransferSecuritySession(
        keyId: transferId,
        transferId: transferId,
        transportMode: TransferTransportMode.chunkedText,
        secretKey: secretKey,
        checksum: checksum,
        finalPath: destinationPath,
        temporaryPath: destinationPath,
      );
    }
    _updateState((items) {
      final nextItems = [...items];
      nextItems.removeWhere((item) => item.id == transferId);
      nextItems.add(
        TransferItem(
          id: transferId,
          direction: TransferDirection.incoming,
          transportMode: nativeFileId == null
              ? TransferTransportMode.chunkedText
              : TransferTransportMode.nativeFile,
          transportReason: nativeFileId == null
              ? 'Received over the encrypted lightweight path.'
              : 'Received over the encrypted native file path.',
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
    final cipherText = payload['cipherText']?.toString();
    final mac = payload['mac']?.toString();
    final chunkIndex = _toInt(payload['chunkIndex']);
    if (transferId == null ||
        cipherText == null ||
        mac == null ||
        chunkIndex == null) {
      return;
    }

    final session = _incomingSessions[transferId];
    if (session == null) return;

    final nonce = await _encryptionService.generateNonce(
      transferId: transferId,
      chunkIndex: chunkIndex,
    );
    final box = SecretBox(
      base64Decode(cipherText),
      nonce: nonce,
      mac: Mac(base64Decode(mac)),
    );
    final chunk = await _encryptionService.decryptBox(
      box: box,
      key: session.secretKey,
    );
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
    final encryptedFileName = file.info.name;
    final finalFileName = _stripEncryptedSuffix(encryptedFileName);
    final encryptedPath = '${saveDirectory.path}/$encryptedFileName';
    final finalPath = '${saveDirectory.path}/$finalFileName';
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
          transportReason:
              'Auto-selected encrypted native Wi-Fi file transfer.',
          peerId: file.info.senderId,
          peerName: file.info.senderId,
          fileName: finalFileName,
          filePath: encryptedPath,
          savedPath: finalPath,
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
        customFileName: encryptedFileName,
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
    final progress = (file.downloadProgressPercent / 100).clamp(0.0, 1.0);
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

    if (isComplete) {
      await _finalizeEncryptedNativeTransfer(
        fileId: file.info.id,
        filePath: existingTransfer.filePath,
        finalPath: existingTransfer.savedPath,
      );
    }
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

  String _stripEncryptedSuffix(String fileName) {
    if (fileName.endsWith(_nativeEncryptedSuffix)) {
      return fileName.substring(
        0,
        fileName.length - _nativeEncryptedSuffix.length,
      );
    }
    return fileName;
  }

  Future<void> _finalizeEncryptedNativeTransfer({
    required String fileId,
    required String? filePath,
    required String? finalPath,
  }) async {
    if (filePath == null || finalPath == null) {
      return;
    }

    final session = _securitySessions[fileId];
    if (session == null) {
      _updateTransfer(
        fileId,
        (item) => item.copyWith(
          status: TransferStatus.failed,
          errorMessage: 'Missing encryption session for native transfer.',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      return;
    }

    final encryptedFile = File(filePath);
    final outputFile = File(finalPath);
    if (!await encryptedFile.exists()) {
      return;
    }

    await outputFile.parent.create(recursive: true);
    final sink = await outputFile.open(mode: FileMode.write);
    try {
      final lines = encryptedFile
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      var isHeader = true;
      var chunkIndex = 0;
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;
        if (isHeader) {
          isHeader = false;
          continue;
        }
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) continue;
        final cipherText = decoded['cipherText']?.toString();
        final mac = decoded['mac']?.toString();
        if (cipherText == null || mac == null) continue;
        final nonce = await _encryptionService.generateNonce(
          transferId: session.transferId,
          chunkIndex: chunkIndex,
        );
        final box = SecretBox(
          base64Decode(cipherText),
          nonce: nonce,
          mac: Mac(base64Decode(mac)),
        );
        final clearChunk = await _encryptionService.decryptBox(
          box: box,
          key: session.secretKey,
        );
        await sink.writeFrom(clearChunk);
        chunkIndex += 1;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    final checksum = await _checksumForFile(outputFile);
    final isValid = checksum == session.checksum;
    if (!isValid) {
      _updateTransfer(
        fileId,
        (item) => item.copyWith(
          status: TransferStatus.failed,
          errorMessage: 'Checksum mismatch',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      return;
    }

    _updateTransfer(
      fileId,
      (item) => item.copyWith(
        status: TransferStatus.completed,
        transferredBytes: item.totalBytes,
        currentChunkIndex: item.chunkCount,
        savedPath: outputFile.path,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
    _securitySessions.remove(fileId);
    _nativeIncomingDownloads.remove(fileId);
    try {
      if (await encryptedFile.exists()) {
        await encryptedFile.delete();
      }
    } catch (_) {}
  }

  double _nativeProgressPercent(HostedFileInfo file) {
    if (file.receiverIds.isEmpty) {
      return 0;
    }
    final receiverId = file.receiverIds.first;
    return (file.getProgressPercent(receiverId).clamp(0.0, 100.0)) / 100.0;
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
      session.secretKey.destroy();
    }
    for (final session in _outgoingSessions.values) {
      session.resumeCompleter?.complete();
      session.secretKey.destroy();
    }
    for (final session in _securitySessions.values) {
      session.secretKey.destroy();
    }
    _incomingSessions.clear();
    _outgoingSessions.clear();
    _securitySessions.clear();
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
  final Uint8List sessionKeyBytes;
  final SecretKey secretKey;
  bool isPaused = false;
  bool isCanceled = false;
  Completer<void>? resumeCompleter;

  _OutgoingTransferSession({
    required this.sourceFile,
    required this.peer,
    required this.transportMode,
    required this.transportReason,
    required this.sessionKeyBytes,
    required this.secretKey,
  });
}

class _IncomingTransferSession {
  final File file;
  final int totalBytes;
  final String checksum;
  final int chunkCount;
  final String peerId;
  final SecretKey secretKey;
  int _receivedBytes = 0;
  late final RandomAccessFile _raf;

  _IncomingTransferSession._({
    required this.file,
    required this.totalBytes,
    required this.checksum,
    required this.chunkCount,
    required this.peerId,
    required this.secretKey,
  });

  static Future<_IncomingTransferSession> create({
    required File file,
    required int totalBytes,
    required String checksum,
    required int chunkCount,
    required String peerId,
    required SecretKey secretKey,
  }) async {
    final session = _IncomingTransferSession._(
      file: file,
      totalBytes: totalBytes,
      checksum: checksum,
      chunkCount: chunkCount,
      peerId: peerId,
      secretKey: secretKey,
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
    secretKey.destroy();
    if (deleteFile) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }
}

class _TransferSecuritySession {
  final String keyId;
  final String transferId;
  final TransferTransportMode transportMode;
  final SecretKey secretKey;
  final String checksum;
  final String? finalPath;
  final String? temporaryPath;

  _TransferSecuritySession({
    required this.keyId,
    required this.transferId,
    required this.transportMode,
    required this.secretKey,
    required this.checksum,
    this.finalPath,
    this.temporaryPath,
  });
}
