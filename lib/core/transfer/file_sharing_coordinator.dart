import 'dart:async';
import 'dart:math';

import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/file_picker_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/storage_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transfer_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_selector_contract.dart';
import 'package:silosend_datasharing_app/core/logging/app_logger.dart';
import 'package:silosend_datasharing_app/core/security/secure_session_manager.dart';
import 'package:silosend_datasharing_app/core/session/session_lifecycle_policy.dart';
import 'package:silosend_datasharing_app/domain/models/transfer_models.dart';

/// High-level coordinator orchestrating the full Phase 9 file sharing experience:
/// file selection, smart transport connection, sliding-window streaming, recipient prompt,
/// full SHA-256 verification, and policy-driven session lifecycle.
class FileSharingCoordinator {
  final TransferEngine transferEngine;
  final TransportSelector transportSelector;
  final FilePickerService filePickerService;
  final StorageService storageService;
  final SecureSessionManager secureSessionManager;
  final SessionLifecyclePolicy sessionLifecyclePolicy;

  final StreamController<List<TransferTask>> _activeTransfersController =
      StreamController<List<TransferTask>>.broadcast();

  final List<TransferTask> _recentCompletedTasks = [];
  final Map<String, DiscoveredPeer> _knownPeers = {};
  final Map<String, DiscoveredPeer> _taskPeers = {};
  bool _isDisposed = false;

  FileSharingCoordinator({
    required this.transferEngine,
    required this.transportSelector,
    required this.filePickerService,
    required this.storageService,
    required this.secureSessionManager,
    required this.sessionLifecyclePolicy,
  });

  /// Stream of pending incoming transfer requests requiring recipient acceptance/decline.
  Stream<IncomingTransferRequest> get incomingRequests =>
      transferEngine.incomingTransferRequests;

  /// Currently active and recently finalized transfer tasks.
  List<TransferTask> get allTransfers {
    final active = transferEngine.activeTransfers;
    final combined = <TransferTask>[...active];
    for (final recent in _recentCompletedTasks) {
      if (!combined.any((t) => t.transferId == recent.transferId)) {
        combined.add(recent);
      }
    }
    return combined;
  }

  /// Reactive stream emitting the list of transfers whenever tasks start, update, or finish.
  Stream<List<TransferTask>> get activeTransfersStream =>
      _activeTransfersController.stream;

  /// Retrieves a previously transferred or discovered peer by [deviceId] (R14).
  DiscoveredPeer? getKnownPeer(String deviceId) => _knownPeers[deviceId];

  /// Caches a known peer for future reconnection or "Share Again" flows (R14).
  void rememberPeer(DiscoveredPeer peer) {
    _knownPeers[peer.deviceId] = peer;
  }

  /// Retains the peer associated with [transferId].
  DiscoveredPeer? getPeerForTask(String transferId) => _taskPeers[transferId];

  /// Dismisses a completed transfer from the active/recent list when user taps "Done" (UI7 & R14).
  void dismissCompletedTask(String transferId) {
    _recentCompletedTasks.removeWhere((t) => t.transferId == transferId);
    _taskPeers.remove(transferId);
    _notifyTransfersChanged();
  }

  /// Reconnects to the known peer [peerDeviceId] and triggers a new transfer without repeating discovery (R14).
  Future<TransferTask?> shareAgain(
    String peerDeviceId, {
    SelectedDocument? preselectedDoc,
  }) async {
    if (_isDisposed) {
      throw StateError('FileSharingCoordinator is disposed');
    }
    final peer = _knownPeers[peerDeviceId];
    if (peer == null) {
      AppLogger.warning(
        'FileSharingCoordinator',
        'Cannot share again: peer $peerDeviceId not found in known peers cache',
      );
      throw StateError('Peer $peerDeviceId is not found in known peers');
    }
    return sendFileToPeer(peer, preselectedDoc: preselectedDoc);
  }

  void _notifyTransfersChanged() {
    if (_isDisposed) return;
    _activeTransfersController.add(allTransfers);
  }

  /// Initiates an outbound file transfer to [peer].
  ///
  /// Prompts the user with the platform file picker if [preselectedDoc] is omitted.
  /// Returns the initiated [TransferTask], or `null` if the user cancelled the picker.
  Future<TransferTask?> sendFileToPeer(
    DiscoveredPeer peer, {
    SelectedDocument? preselectedDoc,
  }) async {
    if (_isDisposed) {
      throw StateError('FileSharingCoordinator is disposed');
    }

    final doc = preselectedDoc ?? await filePickerService.pickDocument();
    if (doc == null) {
      AppLogger.info(
        'FileSharingCoordinator',
        'User cancelled document picker',
      );
      return null;
    }

    AppLogger.info(
      'FileSharingCoordinator',
      'Preparing outbound transfer of "${doc.name}" (${doc.sizeBytes} bytes) to ${peer.displayName}',
    );

    _knownPeers[peer.deviceId] = peer;

    // Keep the source open for the task, then close it on success or failure.
    final source = filePickerService.createPayloadSource(doc);
    String? activeSessionId;
    var transferStarted = false;

    try {
      // 1. Connect or reuse existing authenticated SecureSession via Smart Transport Selection
      final session = await transportSelector.connectWithSmartSelection(
        peer,
        request: TransportSelectionRequest(
          targetPeer: peer,
          payloadSizeBytes: doc.sizeBytes > 0 ? doc.sizeBytes : 0,
        ),
      );
      activeSessionId = session.sessionId;

      // 2. Compute streaming SHA-256 digest
      final sha256Checksum = await source.computeSha256();

      // 3. Construct TransferMetadata
      final chunkSize = 64 * 1024;
      final totalBytes = doc.sizeBytes > 0 ? doc.sizeBytes : source.length;
      final transferId = _generateTransferId();

      final metadata = TransferMetadata(
        transferId: transferId,
        fileName: doc.name,
        totalBytes: totalBytes,
        chunkSize: chunkSize,
        sha256Checksum: sha256Checksum,
        payloadType: PayloadType.file,
        mimeType: doc.mimeType ?? 'application/octet-stream',
      );

      // 4. Notify lifecycle policy that transfer is active
      sessionLifecyclePolicy.markTransferStarted(session.sessionId);
      transferStarted = true;

      // 5. Start sliding-window outbound transfer pipeline
      final task = await transferEngine.sendPayload(
        targetDeviceId: peer.deviceId,
        source: source,
        metadata: metadata,
      );

      _taskPeers[task.transferId] = peer;
      task.done.whenComplete(source.close).ignore();
      _trackTask(task, session.sessionId);
      _notifyTransfersChanged();

      return task;
    } catch (_) {
      if (transferStarted && activeSessionId != null) {
        sessionLifecyclePolicy.markTransferEnded(activeSessionId);
      }
      await source.close();
      rethrow;
    }
  }

  /// Outbound: orchestrates sending multiple documents [documents] to [peer]
  /// sequentially over a single authenticated [SecureSession].
  ///
  /// Reuses the existing session across files without renegotiating handshakes or tearing down
  /// prematurely, starting the grace period only after the final file completes.
  Future<List<TransferTask>> sendFilesToPeer({
    required DiscoveredPeer peer,
    required List<SelectedDocument> documents,
    int chunkSize = 64 * 1024,
  }) async {
    if (_isDisposed) {
      throw StateError('FileSharingCoordinator is disposed');
    }
    if (documents.isEmpty) return [];

    _knownPeers[peer.deviceId] = peer;

    // Connect or reuse existing authenticated session once for the entire batch
    final session = await transportSelector.connectWithSmartSelection(
      peer,
      request: TransportSelectionRequest(
        targetPeer: peer,
        payloadSizeBytes: documents.fold<int>(
          0,
          (sum, d) => sum + (d.sizeBytes > 0 ? d.sizeBytes : 0),
        ),
      ),
    );

    final tasks = <TransferTask>[];
    for (final doc in documents) {
      final source = filePickerService.createPayloadSource(doc);
      try {
        sessionLifecyclePolicy.markTransferStarted(session.sessionId);
        final sha256Checksum = await source.computeSha256();
        final totalBytes = doc.sizeBytes > 0 ? doc.sizeBytes : source.length;
        final transferId = _generateTransferId();

        final metadata = TransferMetadata(
          transferId: transferId,
          fileName: doc.name,
          totalBytes: totalBytes,
          chunkSize: chunkSize,
          sha256Checksum: sha256Checksum,
          payloadType: PayloadType.file,
          mimeType: doc.mimeType ?? 'application/octet-stream',
        );

        final task = await transferEngine.sendPayload(
          targetDeviceId: peer.deviceId,
          source: source,
          metadata: metadata,
        );

        _taskPeers[task.transferId] = peer;
        task.done.whenComplete(source.close).ignore();
        _trackTask(task, session.sessionId);
        _notifyTransfersChanged();
        tasks.add(task);

        // Await completion of current file before initiating the next file in batch
        // to prevent chunk interleaving or socket contention.
        await task.done;
      } catch (e) {
        await source.close();
        sessionLifecyclePolicy.markTransferEnded(session.sessionId);
        rethrow;
      }
    }

    return tasks;
  }

  /// Accepts an incoming file transfer request, saving the verified file to the
  /// platform downloads directory (or [customSaveDirectory]).
  Future<TransferTask> acceptIncomingTransfer(
    IncomingTransferRequest request, {
    String? customSaveDirectory,
  }) async {
    if (_isDisposed) {
      throw StateError('FileSharingCoordinator is disposed');
    }

    final downloadsDir =
        customSaveDirectory ?? await storageService.getDownloadsDirectory();
    final destinationPath = await storageService.resolveUniqueDestinationPath(
      downloadsDir,
      request.metadata.fileName,
    );

    AppLogger.info(
      'FileSharingCoordinator',
      'Accepting incoming transfer "${request.metadata.fileName}" -> $destinationPath',
    );

    // Find session for this peer
    final session = secureSessionManager.getSessionForPeer(
      request.senderDeviceId,
    );
    final sessionId = session?.sessionId ?? request.senderDeviceId;

    if (session != null && !_knownPeers.containsKey(request.senderDeviceId)) {
      final info = session.connectionSession.info;
      _knownPeers[request.senderDeviceId] = DiscoveredPeer(
        deviceId: request.senderDeviceId,
        displayName: info.remoteDisplayName ?? 'SiloSend Peer',
        transportType: info.activeTransport,
        rssi: 0,
        endpointAddress:
            info.remoteAddress != null && info.remotePort != null
                ? '${info.remoteAddress}:${info.remotePort}'
                : null,
        lastSeen: DateTime.now(),
      );
    }

    sessionLifecyclePolicy.markTransferStarted(sessionId);

    final task = await request.accept(destinationPath);
    final knownPeer = _knownPeers[request.senderDeviceId];
    if (knownPeer != null) {
      _taskPeers[task.transferId] = knownPeer;
    }

    _trackTask(task, sessionId, mediaScanPath: destinationPath);
    _notifyTransfersChanged();

    return task;
  }

  /// Declines an incoming file transfer request with an optional [reason].
  Future<void> declineIncomingTransfer(
    IncomingTransferRequest request, {
    String? reason,
  }) async {
    AppLogger.info(
      'FileSharingCoordinator',
      'Declining incoming transfer "${request.metadata.fileName}" (Reason: $reason)',
    );
    await request.decline(reason ?? 'Declined by recipient');
    _notifyTransfersChanged();
  }

  void _trackTask(
    TransferTask task,
    String sessionId, {
    String? mediaScanPath,
  }) {
    task.progressStream.listen((_) {
      _notifyTransfersChanged();
    });

    task.done.whenComplete(() async {
      if (mediaScanPath != null && task.status == TransferStatus.completed) {
        try {
          await storageService.notifyMediaScanner(mediaScanPath);
        } catch (_) {}
      }
      if (!_recentCompletedTasks.any((t) => t.transferId == task.transferId)) {
        _recentCompletedTasks.insert(0, task);
        if (_recentCompletedTasks.length > 20) {
          _recentCompletedTasks.removeLast();
        }
      }
      sessionLifecyclePolicy.markTransferEnded(sessionId);
      _notifyTransfersChanged();
    }).ignore();
  }

  String _generateTransferId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void dispose() {
    _isDisposed = true;
    _activeTransfersController.close();
  }
}
