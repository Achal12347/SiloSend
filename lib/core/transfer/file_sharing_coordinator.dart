import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/storage_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/session/session_lifecycle_policy.dart';
import 'package:vayu/core/transfer/receive_ticket.dart';
import 'package:vayu/core/transfer/transfer_batch.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/core/transfer/transfer_keep_alive_controller.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/transfer/payload_source.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';

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

  /// Keeps the device awake for long transfers; null where none is needed.
  final TransferKeepAliveController? keepAliveController;

  /// App-private folder for received contact cards (Android); null elsewhere.
  final Future<String?> Function()? contactDirectory;

  /// Finished transfers kept across restarts; null keeps none.
  final TransferHistory? history;

  final StreamController<List<TransferTask>> _activeTransfersController =
      StreamController<List<TransferTask>>.broadcast();

  final List<TransferTask> _recentCompletedTasks = [];
  final Map<String, DiscoveredPeer> _knownPeers = {};
  final Map<String, DiscoveredPeer> _taskPeers = {};

  final Map<String, TransferBatch> _batches = {};
  final Map<String, String> _taskBatch = {};
  final StreamController<IncomingTransferRequest> _incomingRequestsController =
      StreamController<IncomingTransferRequest>.broadcast();
  final StreamController<IncomingBatchRequest> _incomingBatchesController =
      StreamController<IncomingBatchRequest>.broadcast();
  final StreamController<TransferBatch> _autoAcceptedController =
      StreamController<TransferBatch>.broadcast();

  // Receiving side: the ticket shown on the Receive screen, while open.
  String? _receiveTicket;
  DateTime? _receiveUntil;

  // Sending side: tickets scanned or tapped from receivers, by device ID.
  final Map<String, (String, DateTime)> _ticketsFromReceivers = {};

  /// How long a Receive ticket (shown or scanned) stays valid.
  static const Duration receiveTicketLifetime = Duration(minutes: 10);

  late final StreamSubscription<IncomingTransferRequest> _engineRequestsSub;
  late final StreamSubscription<IncomingBatchRequest> _engineBatchesSub;
  bool _isDisposed = false;

  FileSharingCoordinator({
    required this.transferEngine,
    required this.transportSelector,
    required this.filePickerService,
    required this.storageService,
    required this.secureSessionManager,
    required this.sessionLifecyclePolicy,
    this.keepAliveController,
    this.contactDirectory,
    this.history,
  }) {
    _engineRequestsSub = transferEngine.incomingTransferRequests.listen(
      _onEngineRequest,
    );
    _engineBatchesSub = transferEngine.incomingBatchRequests.listen(
      _onEngineBatch,
    );
  }

  void Function() _holdKeepAlive(String text) {
    return keepAliveController?.acquire(title: 'Vayu', text: text) ?? () {};
  }

  /// Incoming single-file offers that need the user's decision. Files covered
  /// by a batch the user already accepted are accepted here automatically and
  /// never appear on this stream.
  Stream<IncomingTransferRequest> get incomingRequests =>
      _incomingRequestsController.stream;

  /// Incoming batch offers: one decision covers every file listed.
  Stream<IncomingBatchRequest> get incomingBatchRequests =>
      _incomingBatchesController.stream;

  // ------------------------------------------------------------ receive

  /// Batches accepted without a prompt because the sender proved it scanned
  /// or tapped this phone's Receive ticket.
  Stream<TransferBatch> get autoAcceptedBatches =>
      _autoAcceptedController.stream;

  /// True while a Receive screen's ticket is valid.
  bool get isReceiving =>
      _receiveTicket != null &&
      _receiveUntil != null &&
      DateTime.now().isBefore(_receiveUntil!);

  /// When the current Receive session ends, if one is open.
  DateTime? get receiveSessionEndsAt => isReceiving ? _receiveUntil : null;

  /// Opens a Receive session for [ticketHex] (the secret in the code this
  /// phone shows). Offers carrying a valid proof for it are accepted without
  /// a prompt until [endReceiveSession] or the lifetime runs out.
  void startReceiveSession(
    String ticketHex, {
    Duration lifetime = receiveTicketLifetime,
  }) {
    _receiveTicket = ticketHex.toLowerCase();
    _receiveUntil = DateTime.now().add(lifetime);
  }

  void endReceiveSession() {
    _receiveTicket = null;
    _receiveUntil = null;
  }

  /// Sending side: remembers the ticket read from [deviceId]'s Receive code,
  /// so files sent to it soon after carry a proof.
  void rememberReceiveTicket(String deviceId, String ticketHex) {
    _ticketsFromReceivers[deviceId.toLowerCase()] = (
      ticketHex.toLowerCase(),
      DateTime.now().add(receiveTicketLifetime),
    );
  }

  /// Whether files sent to [deviceId] now would carry a Receive proof.
  bool hasReceiveTicketFor(String deviceId) => _ticketFor(deviceId) != null;

  String? _ticketFor(String deviceId) {
    final entry = _ticketsFromReceivers[deviceId.toLowerCase()];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.$2)) {
      _ticketsFromReceivers.remove(deviceId.toLowerCase());
      return null;
    }
    return entry.$1;
  }

  Future<void> _onEngineBatch(IncomingBatchRequest request) async {
    if (_isDisposed) return;
    final ticket = _receiveTicket;
    final proof = request.receiveProof;
    final proven =
        isReceiving &&
        ticket != null &&
        proof != null &&
        ReceiveTicket.verify(
          ticketHex: ticket,
          senderDeviceId: request.senderDeviceId,
          batchId: request.batchId,
          proofHex: proof,
        );
    if (proven) {
      AppLogger.info(
        'FileSharingCoordinator',
        'Accepting ${request.files.length} file(s) from a sender holding our Receive ticket',
      );
      try {
        final batch = await acceptIncomingBatch(request);
        if (!_autoAcceptedController.isClosed) {
          _autoAcceptedController.add(batch);
        }
      } catch (e) {
        // acceptIncomingBatch already declined with the real reason
        // (for example not enough space).
        AppLogger.warning('FileSharingCoordinator', 'Auto-accept failed: $e');
      }
      return;
    }
    if (!_incomingBatchesController.isClosed) {
      _incomingBatchesController.add(request);
    }
  }

  /// The batch [transferId] belongs to, if any.
  TransferBatch? batchForTask(String transferId) {
    final id = _taskBatch[transferId];
    return id == null ? null : _batches[id];
  }

  /// Batch by ID.
  TransferBatch? getBatch(String batchId) => _batches[batchId];

  /// Most recently created batch with [peerDeviceId] in the given direction.
  TransferBatch? latestBatchForPeer(String peerDeviceId, {bool? outbound}) {
    TransferBatch? latest;
    for (final batch in _batches.values) {
      if (batch.peerDeviceId != peerDeviceId) continue;
      if (outbound != null && batch.outbound != outbound) continue;
      latest = batch;
    }
    return latest;
  }

  void _onEngineRequest(IncomingTransferRequest request) {
    if (_isDisposed) return;
    // Auto-accept only files of a batch this coordinator accepted itself;
    // anything else is shown to the user as a normal offer.
    if (request.authorizedBatchId != null &&
        _batches.containsKey(request.authorizedBatchId)) {
      _acceptAuthorizedFile(request);
      return;
    }
    if (!_incomingRequestsController.isClosed) {
      _incomingRequestsController.add(request);
    }
  }

  /// Accepts a file the engine matched to an accepted batch.
  Future<void> _acceptAuthorizedFile(IncomingTransferRequest request) async {
    final batch = _batches[request.authorizedBatchId];
    final index = BatchFileMarker.tryDecode(request.metadata.extraMetadata)
        ?.index;
    try {
      final task = await acceptIncomingTransfer(request);
      if (batch != null && index != null && index < batch.fileCount) {
        batch.tasks[index] = task;
        batch.failures.remove(index);
        _taskBatch[task.transferId] = batch.batchId;
        _notifyTransfersChanged();
      }
    } catch (e) {
      AppLogger.warning(
        'FileSharingCoordinator',
        'Could not accept "${request.metadata.fileName}" from an accepted batch: $e',
      );
      if (batch != null && index != null && index < batch.fileCount) {
        batch.failures[index] = e;
        _updateInboundBatchState(batch);
      }
    }
  }

  /// Accepts every file of [request]: checks free space for the whole batch,
  /// then records consent so the files arrive without further prompts.
  Future<TransferBatch> acceptIncomingBatch(
    IncomingBatchRequest request,
  ) async {
    if (_isDisposed) {
      throw StateError('FileSharingCoordinator is disposed');
    }
    final directory = await storageService.getDownloadsDirectory();
    final free = await storageService.getFreeBytes(directory);
    if (free != null && free < request.totalBytes + freeSpaceMarginBytes) {
      try {
        await request.declineWithCode(
          TransferCancelReason.storageFull,
          'Not enough storage space on the receiving device',
        );
      } catch (_) {}
      throw InsufficientStorageException(
        request.batchId,
        requiredBytes: request.totalBytes,
        freeBytes: free,
      );
    }

    final batch = TransferBatch(
      batchId: request.batchId,
      peerDeviceId: request.senderDeviceId,
      outbound: false,
      fileNames: [for (final f in request.files) f.fileName],
      fileSizes: [for (final f in request.files) f.sizeBytes],
    );
    _batches[batch.batchId] = batch;
    await request.accept();
    _notifyTransfersChanged();
    return batch;
  }

  /// Refuses a whole incoming batch.
  Future<void> declineIncomingBatch(
    IncomingBatchRequest request, {
    String? reason,
  }) => request.decline(reason);

  void _updateInboundBatchState(TransferBatch batch) {
    if (batch.outbound) return;
    final settled = <int>{
      ...batch.failures.keys,
      for (final e in batch.tasks.entries)
        if (e.value.status == TransferStatus.completed) e.key,
    };
    if (settled.length >= batch.fileCount) {
      batch.state = batch.failures.isEmpty
          ? TransferBatchState.completed
          : TransferBatchState.completedWithFailures;
    }
    _notifyTransfersChanged();
  }

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

    return _sendSource(
      peer,
      source: filePickerService.createPayloadSource(doc),
      fileName: doc.name,
      declaredSize: doc.sizeBytes,
      mimeType: doc.mimeType ?? 'application/octet-stream',
      payloadType: PayloadType.file,
    );
  }

  /// Sends one contact card (vCard) to [peer] over the same encrypted engine.
  Future<TransferTask> sendContactToPeer(
    DiscoveredPeer peer, {
    required String name,
    required Uint8List vcard,
  }) async {
    if (_isDisposed) {
      throw StateError('FileSharingCoordinator is disposed');
    }
    if (ContactCard.tryParse(vcard) == null) {
      throw ArgumentError('Not a valid contact card');
    }
    final task = await _sendSource(
      peer,
      source: MemoryPayloadSource(vcard),
      fileName: ContactCard.fileNameFor(name),
      declaredSize: vcard.length,
      mimeType: 'text/vcard',
      payloadType: PayloadType.contact,
    );
    return task!;
  }

  // Shared core of every outbound send: connect, hash, offer, track.
  Future<TransferTask?> _sendSource(
    DiscoveredPeer peer, {
    required PayloadSource source,
    required String fileName,
    required int declaredSize,
    required String mimeType,
    required PayloadType payloadType,
  }) async {
    _knownPeers[peer.deviceId] = peer;

    // Held from before hashing until the task settles: hashing a large file
    // takes long enough for Android to freeze an unprotected app.
    final releaseKeepAlive = _holdKeepAlive('Sending $fileName');

    String? activeSessionId;
    var transferStarted = false;

    try {
      // 1. Connect or reuse existing authenticated SecureSession via Smart Transport Selection
      final session = await transportSelector.connectWithSmartSelection(
        peer,
        request: TransportSelectionRequest(
          targetPeer: peer,
          payloadSizeBytes: declaredSize > 0 ? declaredSize : 0,
        ),
      );
      activeSessionId = session.sessionId;

      // Mark active before hashing so idle teardown cannot fire while a large
      // file is still being digested.
      sessionLifecyclePolicy.markTransferStarted(session.sessionId);
      transferStarted = true;

      // 2. Compute streaming SHA-256 digest
      final sha256Checksum = await source.computeSha256();

      // 3. Construct TransferMetadata
      final chunkSize = transferEngine.chunkSizeFor(peer.deviceId);
      final totalBytes = declaredSize > 0 ? declaredSize : source.length;
      final transferId = _generateTransferId();

      final metadata = TransferMetadata(
        transferId: transferId,
        fileName: fileName,
        totalBytes: totalBytes,
        chunkSize: chunkSize,
        sha256Checksum: sha256Checksum,
        payloadType: payloadType,
        mimeType: mimeType,
      );

      // 4. Start sliding-window outbound transfer pipeline
      final task = await transferEngine.sendPayload(
        targetDeviceId: peer.deviceId,
        source: source,
        metadata: metadata,
      );

      _taskPeers[task.transferId] = peer;
      task.done.whenComplete(source.close).ignore();
      task.done.whenComplete(releaseKeepAlive).ignore();
      _trackTask(task, session.sessionId);
      _notifyTransfersChanged();

      return task;
    } catch (_) {
      if (transferStarted && activeSessionId != null) {
        sessionLifecyclePolicy.markTransferEnded(activeSessionId);
      }
      releaseKeepAlive();
      await source.close();
      rethrow;
    }
  }

  /// Outbound: orchestrates sending multiple documents [documents] to [peer]
  /// sequentially over a single authenticated [SecureSession].
  ///
  /// Reuses the existing session across files without renegotiating handshakes or tearing down
  /// prematurely, starting the grace period only after the final file completes.
  ///
  /// [chunkSize] overrides the size chosen for the link (tests only).
  Future<List<TransferTask>> sendFilesToPeer({
    required DiscoveredPeer peer,
    required List<SelectedDocument> documents,
    int? chunkSize,
  }) async {
    if (_isDisposed) {
      throw StateError('FileSharingCoordinator is disposed');
    }
    if (documents.isEmpty) return [];

    _knownPeers[peer.deviceId] = peer;

    // One keep-alive reference covers the whole batch, including hashing.
    final releaseKeepAlive = _holdKeepAlive(
      'Sending ${documents.length} file${documents.length == 1 ? '' : 's'}',
    );
    try {
      return await _sendBatch(peer, documents, chunkSize);
    } finally {
      releaseKeepAlive();
    }
  }

  Future<List<TransferTask>> _sendBatch(
    DiscoveredPeer peer,
    List<SelectedDocument> documents,
    int? chunkSizeOverride,
  ) async {
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

    // One consent for the whole batch when the receiver's build supports it;
    // otherwise each file is offered (and prompted) on its own as before.
    final ticket = _ticketFor(peer.deviceId);
    final offerAsBatch =
        (documents.length > 1 || ticket != null) &&
        documents.every((d) => d.sizeBytes >= 0) &&
        documents.length <= TransferBatchOfferPayload.maxFiles &&
        transferEngine.supportsBatchOffers(peer.deviceId);

    final batch = TransferBatch(
      batchId: _generateTransferId(),
      peerDeviceId: peer.deviceId,
      outbound: true,
      fileNames: [for (final d in documents) d.name],
      fileSizes: [for (final d in documents) d.sizeBytes],
      documents: List.unmodifiable(documents),
      offeredAsBatch: offerAsBatch,
      state: offerAsBatch
          ? TransferBatchState.awaitingConsent
          : TransferBatchState.transferring,
    );
    _batches[batch.batchId] = batch;
    _notifyTransfersChanged();

    if (offerAsBatch) {
      try {
        await transferEngine.offerBatch(
          targetDeviceId: peer.deviceId,
          batchId: batch.batchId,
          files: [
            for (final d in documents)
              BatchManifestEntry(
                fileName: d.name,
                sizeBytes: d.sizeBytes,
                mimeType: d.mimeType ?? 'application/octet-stream',
              ),
          ],
          receiveProof: ticket == null
              ? null
              : ReceiveTicket.proof(
                  ticketHex: ticket,
                  senderDeviceId: secureSessionManager.localIdentity.idHex,
                  batchId: batch.batchId,
                ),
        );
      } catch (e) {
        batch.state = e is TransferBatchDeclinedException
            ? TransferBatchState.declined
            : TransferBatchState.failed;
        batch.error = e;
        _notifyTransfersChanged();
        rethrow;
      }
      batch.state = TransferBatchState.transferring;
      _notifyTransfersChanged();
    }

    await _sendBatchFiles(batch, peer, session.sessionId, [
      for (var i = 0; i < documents.length; i++) i,
    ], chunkSizeOverride ?? transferEngine.chunkSizeFor(peer.deviceId));
    return [
      for (var i = 0; i < documents.length; i++)
        if (batch.tasks[i] != null) batch.tasks[i]!,
    ];
  }

  /// Sends the files at [indices] one after another. A failed file is
  /// recorded and the next one still goes; only a lost connection stops the
  /// rest (they are marked failed so they can be retried together).
  Future<void> _sendBatchFiles(
    TransferBatch batch,
    DiscoveredPeer peer,
    String sessionId,
    List<int> indices,
    int chunkSize,
  ) async {
    for (var n = 0; n < indices.length; n++) {
      final i = indices[n];
      final doc = batch.documents[i];
      batch.failures.remove(i);
      final source = filePickerService.createPayloadSource(doc);
      // Once tracked, the task's own completion handler ends the transfer.
      var tracked = false;
      try {
        sessionLifecyclePolicy.markTransferStarted(sessionId);
        final sha256Checksum = await source.computeSha256();
        final totalBytes = doc.sizeBytes > 0 ? doc.sizeBytes : source.length;

        final metadata = TransferMetadata(
          transferId: _generateTransferId(),
          fileName: doc.name,
          totalBytes: totalBytes,
          chunkSize: chunkSize,
          sha256Checksum: sha256Checksum,
          payloadType: PayloadType.file,
          mimeType: doc.mimeType ?? 'application/octet-stream',
          extraMetadata: batch.offeredAsBatch
              ? BatchFileMarker(batchIdHex: batch.batchId, index: i).encode()
              : null,
        );

        final task = await transferEngine.sendPayload(
          targetDeviceId: peer.deviceId,
          source: source,
          metadata: metadata,
        );

        _taskPeers[task.transferId] = peer;
        task.done.whenComplete(source.close).ignore();
        _trackTask(task, sessionId);
        tracked = true;
        batch.tasks[i] = task;
        _taskBatch[task.transferId] = batch.batchId;
        _notifyTransfersChanged();

        // Await completion of current file before initiating the next file in batch
        // to prevent chunk interleaving or socket contention.
        await task.done;
      } catch (e) {
        if (!tracked) {
          await source.close();
          sessionLifecyclePolicy.markTransferEnded(sessionId);
        }
        batch.failures[i] = e;
        _notifyTransfersChanged();
        AppLogger.warning(
          'FileSharingCoordinator',
          'File ${i + 1}/${batch.fileCount} of batch failed: $e',
        );

        final live = secureSessionManager.getSessionForPeer(peer.deviceId);
        if (live == null || !live.isEstablished) {
          for (final rest in indices.skip(n + 1)) {
            batch.failures[rest] = e;
          }
          break;
        }
      }
    }
    batch.state = batch.failures.isEmpty
        ? TransferBatchState.completed
        : TransferBatchState.completedWithFailures;
    _notifyTransfersChanged();
  }

  /// Sends again only the files of [batchId] that failed. Files that already
  /// arrived are never resent. Reconnects if needed.
  Future<void> retryFailedFiles(String batchId) async {
    if (_isDisposed) {
      throw StateError('FileSharingCoordinator is disposed');
    }
    final batch = _batches[batchId];
    if (batch == null || !batch.outbound || batch.documents.isEmpty) {
      throw StateError('No retryable outbound batch $batchId');
    }
    if (!batch.isFinished || batch.failures.isEmpty) return;
    final peer = _knownPeers[batch.peerDeviceId];
    if (peer == null) {
      throw StateError('Peer ${batch.peerDeviceId} is no longer known');
    }

    final indices = batch.failures.keys.toList()..sort();
    final releaseKeepAlive = _holdKeepAlive(
      'Sending ${indices.length} file${indices.length == 1 ? '' : 's'}',
    );
    try {
      final size = [for (final i in indices) batch.fileSizes[i]]
          .fold<int>(0, (sum, s) => sum + (s > 0 ? s : 0));
      final session = await transportSelector.connectWithSmartSelection(
        peer,
        request: TransportSelectionRequest(
          targetPeer: peer,
          payloadSizeBytes: size,
        ),
      );
      batch.state = TransferBatchState.transferring;
      batch.error = null;
      _notifyTransfersChanged();
      // Files keep their batch tag: while the receiver's consent for this
      // batch is still valid they arrive without a prompt, otherwise the
      // receiver is asked per file.
      await _sendBatchFiles(
        batch,
        peer,
        session.sessionId,
        indices,
        transferEngine.chunkSizeFor(peer.deviceId),
      );
    } finally {
      releaseKeepAlive();
    }
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

    final isContact = request.metadata.payloadType == PayloadType.contact;
    if (isContact && request.metadata.totalBytes > ContactCard.maxBytes) {
      await request.decline('Contact card too large');
      throw StateError('Contact card too large');
    }
    // Contact cards stay app-private until the user saves them to contacts.
    final privateDir = isContact ? await contactDirectory?.call() : null;
    final downloadsDir =
        customSaveDirectory ??
        privateDir ??
        await storageService.getDownloadsDirectory();
    await _ensureFreeSpace(request, downloadsDir);
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
        displayName: info.remoteDisplayName ?? 'Vayu Peer',
        transportType: info.activeTransport,
        rssi: 0,
        endpointAddress: info.remoteAddress != null && info.remotePort != null
            ? '${info.remoteAddress}:${info.remotePort}'
            : null,
        lastSeen: DateTime.now(),
      );
    }

    sessionLifecyclePolicy.markTransferStarted(sessionId);

    final releaseKeepAlive = _holdKeepAlive(
      'Receiving ${request.metadata.fileName}',
    );
    final TransferTask task;
    try {
      task = await request.accept(destinationPath);
    } catch (_) {
      releaseKeepAlive();
      sessionLifecyclePolicy.markTransferEnded(sessionId);
      rethrow;
    }
    task.done.whenComplete(releaseKeepAlive).ignore();
    final knownPeer = _knownPeers[request.senderDeviceId];
    if (knownPeer != null) {
      _taskPeers[task.transferId] = knownPeer;
    }

    _trackTask(task, sessionId, mediaScanPath: destinationPath);
    _notifyTransfersChanged();

    return task;
  }

  /// Space kept free beyond the file itself so the phone is not filled to zero.
  static const int freeSpaceMarginBytes = 20 * 1024 * 1024;

  /// Declines [request] with the real reason when [directory] cannot hold it,
  /// and throws [InsufficientStorageException]. Skipped when the platform
  /// cannot report free space.
  Future<void> _ensureFreeSpace(
    IncomingTransferRequest request,
    String directory,
  ) async {
    final free = await storageService.getFreeBytes(directory);
    final needed = request.metadata.totalBytes + freeSpaceMarginBytes;
    if (free == null || free >= needed) return;

    AppLogger.warning(
      'FileSharingCoordinator',
      'Not enough space for "${request.metadata.fileName}": needs $needed, free $free',
    );
    try {
      await request.declineWithCode(
        TransferCancelReason.storageFull,
        'Not enough storage space on the receiving device',
      );
    } catch (_) {}
    throw InsufficientStorageException(
      request.transferId,
      requiredBytes: request.metadata.totalBytes,
      freeBytes: free,
    );
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
    task.done.then(
      (_) => _onTaskSettled(task, null, mediaScanPath),
      onError: (Object e) => _onTaskSettled(task, e, mediaScanPath),
    );
    task.progressStream.listen((progress) {
      _notifyTransfersChanged();
      keepAliveController?.report(
        title: 'Vayu',
        text:
            '${task is InboundTransferTask ? 'Receiving' : 'Sending'} '
            '${task.metadata.fileName} · ${progress.percentage}%',
        progress: progress.percentage,
      );
    }, onError: (_) {});

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

  void _onTaskSettled(TransferTask task, Object? error, String? savedPath) {
    _onBatchTaskSettled(task, error);
    _recordHistory(task, error, savedPath);
  }

  void _recordHistory(TransferTask task, Object? error, String? savedPath) {
    final log = history;
    if (log == null || _isDisposed) return;
    final outcome = error == null
        ? TransferOutcome.completed
        : task.status == TransferStatus.cancelled
        ? TransferOutcome.cancelled
        : TransferOutcome.failed;
    final peerName =
        _taskPeers[task.transferId]?.displayName ??
        _knownPeers[task.remoteDeviceId]?.displayName ??
        'Nearby device';
    log
        .add(
          TransferHistoryRecord(
            transferId: task.transferId,
            batchId: _taskBatch[task.transferId],
            outbound: task is! InboundTransferTask,
            peerDeviceId: task.remoteDeviceId,
            peerName: peerName,
            fileName: task.metadata.fileName,
            sizeBytes: task.metadata.totalBytes,
            mimeType: task.metadata.mimeType,
            isContact: task.metadata.payloadType == PayloadType.contact,
            outcome: outcome,
            failureKind: error == null ? null : transferFailureKind(error).name,
            finishedAt: DateTime.now(),
            savedPath: error == null ? savedPath : null,
          ),
        )
        .ignore();
    _notifyTransfersChanged();
  }

  void _onBatchTaskSettled(TransferTask task, Object? error) {
    final batch = batchForTask(task.transferId);
    if (batch == null || batch.outbound) return;
    final index = batch.indexOf(task.transferId);
    if (index == null) return;
    if (error != null) batch.failures[index] = error;
    _updateInboundBatchState(batch);
  }

  String _generateTransferId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void dispose() {
    _isDisposed = true;
    _engineRequestsSub.cancel();
    _engineBatchesSub.cancel();
    _activeTransfersController.close();
    _autoAcceptedController.close();
    _incomingRequestsController.close();
    _incomingBatchesController.close();
  }
}
