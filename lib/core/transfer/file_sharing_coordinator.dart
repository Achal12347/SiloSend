import 'dart:async';
import 'dart:io';
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
import 'package:vayu/core/transfer/transfer_engine_impl.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/core/transfer/transfer_keep_alive_controller.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/transfer/payload_destination.dart';
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

  /// Told about every contact card received and verified (path, sender).
  final void Function(String path, String peerName)? onContactReceived;

  /// After a batch loses its connection, the sender retries the unfinished
  /// files by itself every [autoResumeDelay] for [autoResumeWindow]. While
  /// the receiver is still on Receive, its consent for the batch and the
  /// part it already has are kept, so the files continue without a prompt.
  final Duration autoResumeDelay;
  final Duration autoResumeWindow;
  final Set<String> _autoResuming = {};

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

  /// Client side of Host & Client: every open download request, by host.
  /// One host can have several (the user asked twice before the first batch
  /// arrived); each keeps its own ticket and the files it asked for.
  final Map<String, List<_HostRequest>> _expectedFromHosts = {};

  final StreamController<TransferBatch> _hostBatchesController =
      StreamController<TransferBatch>.broadcast();

  /// Batches that arrived from a host because this phone asked for them.
  Stream<TransferBatch> get hostBatches => _hostBatchesController.stream;

  /// How long a download request to a host stays answerable.
  static const Duration hostRequestLifetime = Duration(minutes: 5);

  /// Client side: this phone asked [hostDeviceId] for [files] with
  /// [ticketHex]. A batch from that host proving the ticket is accepted
  /// without a prompt, on any screen, only when every file in it is one of
  /// [files] not received yet (a big request may come as several batches).
  void expectFromHost(
    String hostDeviceId,
    String ticketHex,
    List<BatchManifestEntry> files, {
    String? tag,
  }) {
    if (files.isEmpty) return;
    final key = hostDeviceId.toLowerCase();
    final now = DateTime.now();
    (_expectedFromHosts[key] ??= [])
      ..removeWhere((r) => now.isAfter(r.until))
      ..add(
        _HostRequest(ticketHex.toLowerCase(), now.add(hostRequestLifetime), [
          for (final f in files) _expectedKey(f),
        ], tag),
      );
  }

  final StreamController<({String tag, TransferBatch batch})>
  _taggedBatchesController = StreamController.broadcast();

  /// Batches that arrived for an expectation made with a tag (a file
  /// accepted in a chat: the tag is the message ID).
  Stream<({String tag, TransferBatch batch})> get taggedBatches =>
      _taggedBatchesController.stream;

  /// Where each received file was saved, by transfer ID.
  final Map<String, String> _savedPaths = {};

  /// Saved paths of [batch]'s received files, in batch order (null where a
  /// file was not saved).
  List<String?> savedPathsOf(TransferBatch batch) => [
    for (var i = 0; i < batch.fileCount; i++)
      batch.tasks[i] == null ? null : _savedPaths[batch.tasks[i]!.transferId],
  ];

  /// Whether this phone asked [deviceId] for files that have not all
  /// arrived yet (a Host & Client download, an accepted chat file).
  bool isExpectingFilesFrom(String deviceId) {
    final requests = _expectedFromHosts[deviceId.toLowerCase()];
    if (requests == null) return false;
    final now = DateTime.now();
    return requests.any((r) => now.isBefore(r.until));
  }

  static String _expectedKey(BatchManifestEntry f) =>
      '${f.folder ?? ''}/${f.fileName}/${f.sizeBytes}';

  /// The request [request] is one this phone asked its sender for, or null.
  _HostRequest? _requestedBatch(IncomingBatchRequest request) {
    final key = request.senderDeviceId.toLowerCase();
    final requests = _expectedFromHosts[key];
    final proof = request.receiveProof;
    if (requests == null || proof == null) return null;
    final now = DateTime.now();
    requests.removeWhere((r) => now.isAfter(r.until));
    try {
      for (final r in requests) {
        final proven = ReceiveTicket.verify(
          ticketHex: r.ticketHex,
          senderDeviceId: request.senderDeviceId,
          batchId: request.batchId,
          proofHex: proof,
        );
        if (!proven) continue;
        // The ticket is right; the files must also be the ones asked for,
        // so a host cannot push anything else under a client's ticket.
        final remaining = List.of(r.remaining);
        for (final f in request.files) {
          if (!remaining.remove(_expectedKey(f))) return null;
        }
        r.remaining
          ..clear()
          ..addAll(remaining);
        if (remaining.isEmpty) requests.remove(r);
        return r;
      }
      return null;
    } finally {
      if (requests.isEmpty) _expectedFromHosts.remove(key);
    }
  }

  /// When false, offers are accepted (or asked about) only while the
  /// Receive screen is open; all others are declined automatically with the
  /// reason, so nobody nearby can cause popups. Files of a batch already
  /// accepted keep arriving either way. The app always sets false; true
  /// (the default) lets engine-level tests offer files without a screen.
  bool acceptOffersOutsideReceive = true;

  /// True when an offer arriving now may reach the user.
  bool get _offersWelcome =>
      acceptOffersOutsideReceive || isReceiveScreenOpen || isReceiving;

  int _receiveScreens = 0;

  /// True while a Receive screen is open. Offers are welcome then (and
  /// asked about) even without a valid ticket: when no code could be made,
  /// or after the code's ten minutes ran out.
  bool get isReceiveScreenOpen => _receiveScreens > 0;

  void openReceiveScreen() => _receiveScreens++;

  void closeReceiveScreen() {
    if (_receiveScreens > 0) _receiveScreens--;
  }

  String get _notReceivingMessage {
    final name = secureSessionManager.localIdentity.displayName;
    return "$name isn't receiving right now. Ask them to tap Receive.";
  }

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
    this.onContactReceived,
    this.autoResumeDelay = const Duration(seconds: 3),
    this.autoResumeWindow = const Duration(seconds: 30),
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
    final requested = proven ? null : _requestedBatch(request);
    if (requested != null) {
      AppLogger.info(
        'FileSharingCoordinator',
        'Accepting ${request.files.length} file(s) this phone asked for',
      );
      try {
        final batch = await acceptIncomingBatch(request);
        final tag = requested.tag;
        if (tag != null) {
          if (!_taggedBatchesController.isClosed) {
            _taggedBatchesController.add((tag: tag, batch: batch));
          }
        } else if (!_hostBatchesController.isClosed) {
          _hostBatchesController.add(batch);
        }
      } catch (e) {
        AppLogger.warning('FileSharingCoordinator', 'Host download failed: $e');
      }
      return;
    }
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
    if (!_offersWelcome) {
      AppLogger.info(
        'FileSharingCoordinator',
        'Declined a batch: not on the Receive screen',
      );
      request
          .declineWithCode(
            TransferCancelReason.notReceiving,
            _notReceivingMessage,
          )
          .catchError((_) {});
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
    if (!_offersWelcome) {
      AppLogger.info(
        'FileSharingCoordinator',
        'Declined an offer: not on the Receive screen',
      );
      // The plain "declined" code keeps older builds able to show the reason.
      request
          .declineWithCode(TransferCancelReason.declined, _notReceivingMessage)
          .catchError((_) {});
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
      final task = await acceptIncomingTransfer(
        request,
        subfolder: index == null ? null : batch?.folderOf(index),
      );
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
      folders: [for (final f in request.files) f.folder],
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
      _pruneFinished();
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

      // 2. SHA-256: hashed while sending when the receiver allows it, so
      // the offer reaches it at once; otherwise hashed first.
      final lateSha256 = _lateHashFor(peer, source, declaredSize);
      final sha256Checksum = lateSha256 != null
          ? TransferMetadata.deferredSha256
          : await source.computeSha256();

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
        lateSha256: lateSha256,
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

  /// Starts hashing [source] in the background when [peer] accepts the hash
  /// after the offer; null when it must be hashed before offering. Needs a
  /// known size, since the offer states it before the file is read.
  Future<String>? _lateHashFor(
    DiscoveredPeer peer,
    PayloadSource source,
    int declaredSize,
  ) {
    if (declaredSize <= 0 || !transferEngine.supportsLateHash(peer.deviceId)) {
      return null;
    }
    // The task reports a hashing failure; this only stops it from also
    // surfacing as unhandled if the task never starts.
    return source.computeSha256()..ignore();
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

    /// Proof to put on the batch offer instead of a ticket remembered for
    /// [peer] (a host answering one particular download request).
    String? receiveTicket,

    /// Told about each batch as soon as it exists (before it finishes).
    void Function(TransferBatch batch)? onBatch,
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
      // A batch offer lists at most maxFiles files; a bigger selection (a
      // large folder) goes as several batches, one after another.
      const perBatch = TransferBatchOfferPayload.maxFiles;
      if (documents.length <= perBatch ||
          !transferEngine.supportsBatchOffers(peer.deviceId)) {
        return await _sendBatch(
          peer,
          documents,
          chunkSize,
          receiveTicket,
          onBatch,
        );
      }
      final tasks = <TransferTask>[];
      for (var i = 0; i < documents.length; i += perBatch) {
        final part = documents.sublist(i, min(i + perBatch, documents.length));
        tasks.addAll(
          await _sendBatch(peer, part, chunkSize, receiveTicket, onBatch),
        );
      }
      return tasks;
    } finally {
      releaseKeepAlive();
    }
  }

  Future<List<TransferTask>> _sendBatch(
    DiscoveredPeer peer,
    List<SelectedDocument> documents,
    int? chunkSizeOverride,
    String? receiveTicket, [
    void Function(TransferBatch batch)? onBatch,
  ]) async {
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
    final ticket = receiveTicket ?? _ticketFor(peer.deviceId);
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
    onBatch?.call(batch);
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
                folder: d.folder,
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
        final lateSha256 = _lateHashFor(peer, source, doc.sizeBytes);
        final sha256Checksum = lateSha256 != null
            ? TransferMetadata.deferredSha256
            : await source.computeSha256();
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
          lateSha256: lateSha256,
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
    _pruneFinished();
    _notifyTransfersChanged();
    _maybeAutoResume(batch);
  }

  static bool _isConnectionLoss(Object error) =>
      error is TransferConnectionException || error is TransferTimeoutException;

  void _maybeAutoResume(TransferBatch batch) {
    if (_isDisposed ||
        !batch.outbound ||
        batch.failures.isEmpty ||
        !batch.failures.values.every(_isConnectionLoss) ||
        !_autoResuming.add(batch.batchId)) {
      return;
    }
    _autoResume(batch)
        .whenComplete(() => _autoResuming.remove(batch.batchId))
        .ignore();
  }

  Future<void> _autoResume(TransferBatch batch) async {
    final deadline = DateTime.now().add(autoResumeWindow);
    while (!_isDisposed && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(autoResumeDelay);
      // Finished meanwhile, or the user already pressed Retry.
      if (_isDisposed || batch.failures.isEmpty || !batch.isFinished) return;
      AppLogger.info(
        'FileSharingCoordinator',
        'Connection lost; resuming ${batch.failures.length} file(s) automatically',
      );
      try {
        await retryFailedFiles(batch.batchId);
      } catch (e) {
        // Not reachable yet; try again until the window closes.
        AppLogger.info('FileSharingCoordinator', 'Auto-resume attempt: $e');
        continue;
      }
      if (batch.failures.isEmpty ||
          !batch.failures.values.every(_isConnectionLoss)) {
        return;
      }
    }
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
  /// platform downloads directory (or [customSaveDirectory]), inside
  /// [subfolder] when the file came as part of a folder.
  Future<TransferTask> acceptIncomingTransfer(
    IncomingTransferRequest request, {
    String? customSaveDirectory,
    String? subfolder,
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
    final baseDir =
        customSaveDirectory ??
        privateDir ??
        await storageService.getDownloadsDirectory();
    // Sanitized again here: the path must never leave the save folder.
    final folder = isContact
        ? null
        : BatchManifestEntry.sanitizeFolder(subfolder);
    final downloadsDir = folder == null
        ? baseDir
        : [baseDir, ...folder.split('/')].join(Platform.pathSeparator);
    if (folder != null) {
      try {
        await Directory(downloadsDir).create(recursive: true);
      } on FileSystemException catch (e) {
        await request.declineWithCode(
          TransferCancelReason.ioError,
          'The receiving device could not create the folder',
        );
        throw TransferStorageException(
          request.transferId,
          'Could not create $downloadsDir: $e',
          outOfSpace: isOutOfSpaceError(e),
        );
      }
    }
    _cleanStaleStaging(downloadsDir);
    await _ensureFreeSpace(request, downloadsDir);
    // Each transfer gets its own name and staging file, even when several
    // arrive at once with the same file name.
    final destinationPath = await storageService.reserveDestinationPath(
      downloadsDir,
      request.metadata.fileName,
    );
    final stagingPath =
        '$destinationPath${FilePayloadDestination.stagingSuffix}';
    _reservedStaging.add(stagingPath);

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
      // The transfer never started: give the reserved name back.
      _reservedStaging.remove(stagingPath);
      try {
        final staging = File(stagingPath);
        if (staging.existsSync()) staging.deleteSync();
      } catch (_) {}
      rethrow;
    }
    task.done.whenComplete(releaseKeepAlive).ignore();
    task.done.whenComplete(() => _reservedStaging.remove(stagingPath)).ignore();
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
    // Saving may move a file to the next free name; report where it is.
    String? savedPath() {
      final destination = task is InboundTransferTask ? task.destination : null;
      return destination is FilePayloadDestination
          ? destination.targetFilePath
          : mediaScanPath;
    }

    task.done.then(
      (_) => _onTaskSettled(task, null, savedPath()),
      onError: (Object e) => _onTaskSettled(task, e, savedPath()),
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
      final scanPath = savedPath();
      if (mediaScanPath != null &&
          scanPath != null &&
          task.status == TransferStatus.completed) {
        try {
          await storageService.notifyMediaScanner(scanPath);
        } catch (_) {}
      }
      if (!_recentCompletedTasks.any((t) => t.transferId == task.transferId)) {
        _recentCompletedTasks.insert(0, task);
        if (_recentCompletedTasks.length > 20) {
          _recentCompletedTasks.removeLast();
        }
      }
      _pruneFinished();
      sessionLifecyclePolicy.markTransferEnded(sessionId);
      _notifyTransfersChanged();
    }).ignore();
  }

  /// Finished batches kept in memory (for their screens and "Retry failed").
  static const int keepFinishedBatches = 20;

  // Without this every batch and task of the session stayed in memory; a few
  // big folders (thousands of tasks) weigh on low-memory phones. Finished
  // transfers live on in the persistent history.
  void _pruneFinished() {
    final finished = _batches.values.where((b) => b.isFinished).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final excess = finished.length - keepFinishedBatches;
    for (final batch in finished.take(max(0, excess))) {
      _batches.remove(batch.batchId);
      for (final task in batch.tasks.values) {
        _taskBatch.remove(task.transferId);
      }
    }
    final inUse = <String>{
      for (final t in transferEngine.activeTransfers) t.transferId,
      for (final t in _recentCompletedTasks) t.transferId,
      ..._taskBatch.keys,
    };
    _taskPeers.removeWhere((id, _) => !inUse.contains(id));
  }

  final Set<String> _cleanedStagingDirs = {};

  /// Staging files reserved by receives that are being set up or running;
  /// the stale-file sweep must never delete them.
  final Set<String> _reservedStaging = {};

  /// Deletes partial files (`*.vayu.tmp`) left by a receive the app never
  /// finished (killed, phone restarted). Runs once per folder, only while
  /// nothing is being received, and keeps partials held for a resume.
  void _cleanStaleStaging(String dir) {
    if (_cleanedStagingDirs.contains(dir)) return;
    if (transferEngine.activeTransfers.any((t) => t is InboundTransferTask)) {
      return;
    }
    _cleanedStagingDirs.add(dir);
    final engine = transferEngine;
    final kept = engine is TransferEngineImpl
        ? engine.resumable.keptPaths
        : const <String>{};
    try {
      for (final entry in Directory(dir).listSync(followLinks: false)) {
        if (entry is File &&
            entry.path.endsWith(FilePayloadDestination.stagingSuffix) &&
            !kept.contains(entry.path) &&
            !_reservedStaging.contains(entry.path)) {
          entry.deleteSync();
        }
      }
    } catch (e) {
      AppLogger.warning('FileSharingCoordinator', 'Staging cleanup failed: $e');
    }
  }

  void _onTaskSettled(TransferTask task, Object? error, String? savedPath) {
    if (savedPath != null) _savedPaths[task.transferId] = savedPath;
    _onBatchTaskSettled(task, error);
    _recordHistory(task, error, savedPath);
    if (error == null &&
        savedPath != null &&
        task is InboundTransferTask &&
        task.metadata.payloadType == PayloadType.contact &&
        !_isDisposed) {
      onContactReceived?.call(savedPath, _peerNameFor(task));
    }
  }

  String _peerNameFor(TransferTask task) =>
      _taskPeers[task.transferId]?.displayName ??
      _knownPeers[task.remoteDeviceId]?.displayName ??
      'Nearby device';

  void _recordHistory(TransferTask task, Object? error, String? savedPath) {
    final log = history;
    if (log == null || _isDisposed) return;
    final outcome = error == null
        ? TransferOutcome.completed
        : task.status == TransferStatus.cancelled
        ? TransferOutcome.cancelled
        : TransferOutcome.failed;
    final peerName = _peerNameFor(task);
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
    _hostBatchesController.close();
    _taggedBatchesController.close();
    _incomingRequestsController.close();
    _incomingBatchesController.close();
  }
}

/// One download this phone asked a host for (Host & Client, client side).
class _HostRequest {
  final String ticketHex;
  final DateTime until;

  /// Files asked for and not received yet (folder/name/size keys).
  final List<String> remaining;

  /// Set for a chat file (the message ID); null for Host & Client.
  final String? tag;

  _HostRequest(this.ticketHex, this.until, this.remaining, [this.tag]);
}
