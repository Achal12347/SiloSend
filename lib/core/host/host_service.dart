import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
// Same addressing helper the transfer engine uses for every packet.
import 'package:vayu/core/transfer/transfer_task_impl.dart'
    show parseIdTo16Bytes;
import 'package:vayu/domain/host/host_payloads.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';

/// Where a client of this host is.
enum HostClientState {
  /// Opened a private share and has not entered the PIN yet.
  waitingForPin,

  /// Entered a wrong PIN (may try again).
  wrongPin,

  /// Too many wrong PINs: refused for the rest of this hosting.
  blocked,
  browsing,
  queued,

  /// Receiving the files it chose.
  downloading,
  done,
  failed,
}

/// A phone that browsed this host. Every field is what really happened.
class HostClient {
  final String deviceId;
  final String name;
  final HostClientState state;
  final int filesRequested;
  final DateTime lastSeen;

  const HostClient({
    required this.deviceId,
    required this.name,
    required this.state,
    required this.filesRequested,
    required this.lastSeen,
  });

  HostClient copyWith({HostClientState? state, int? filesRequested}) =>
      HostClient(
        deviceId: deviceId,
        name: name,
        state: state ?? this.state,
        filesRequested: filesRequested ?? this.filesRequested,
        lastSeen: DateTime.now(),
      );
}

/// The host could not be reached or would not answer.
class HostUnavailableException implements Exception {
  final String message;
  const HostUnavailableException(this.message);

  @override
  String toString() => 'HostUnavailableException: $message';
}

/// Host & Client: one phone shares a set of files; nearby phones browse it
/// and download what they choose.
///
/// Reuses everything that already exists: discovery (a hosting bit in the
/// beacon), the encrypted sessions (packets 0x50-0x54), and batch transfers
/// for the files themselves. A client's download request carries a
/// one-time ticket; the host's batch proves it holds that ticket, so the
/// client accepts exactly the files it asked for without a prompt.
class HostService {
  final String Function() localDeviceId;
  final SecureSession? Function(String deviceId) sessionFor;

  /// Opens a session with a host (it is in the nearby list).
  final Future<SecureSession> Function(String deviceId) connect;
  final String? Function(SecureSession session) nameOf;

  /// Whether the other phone understands Host & Client (`host-v1`).
  final bool Function(SecureSession session) supportsHost;

  /// Host side: sends [documents] to a client as one batch whose offer
  /// proves [ticketHex]. Completes when the batch has finished.
  final Future<void> Function({
    required String clientDeviceId,
    required String clientName,
    required List<SelectedDocument> documents,
    required String ticketHex,
  })
  sendToClient;

  /// Client side: accept batches from the host proving [ticketHex] that
  /// hold only [files] (what this phone asked for).
  final void Function(
    String hostDeviceId,
    String ticketHex,
    List<BatchManifestEntry> files,
  )
  expectFromHost;

  /// Clients served at the same time; others wait in turn so one host's
  /// Wi-Fi is not split between many transfers at once.
  final int maxConcurrentClients;
  final Duration answerTimeout;

  HostService({
    required this.localDeviceId,
    required this.sessionFor,
    required this.connect,
    required this.nameOf,
    required this.supportsHost,
    required this.sendToClient,
    required this.expectFromHost,
    this.maxConcurrentClients = 2,
    this.answerTimeout = const Duration(seconds: 20),
  });

  final Random _random = Random.secure();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<String> _hostsEnded =
      StreamController<String>.broadcast();
  StreamSubscription<({SecureSession session, VayuPacket packet})>? _sub;

  /// Told when a Host & Client packet goes out on a session.
  void Function(SecureSession session)? onActivity;

  /// Runs when hosting starts or stops (to change what is advertised).
  void Function(bool hosting)? onHostingChanged;

  // ------------------------------------------------------------------ host

  String _shareName = '';
  HostAccess _access = HostAccess.public;
  String? _pin;

  /// Private hosting: clients that entered the right PIN, and wrong tries
  /// per client and in total (by lower-case device ID).
  final Set<String> _admitted = {};
  final Map<String, int> _wrongTries = {};
  int _wrongTotal = 0;

  /// Wrong PINs one client may enter before it is refused.
  static const int maxTriesPerClient = 5;

  /// Wrong PINs from all clients after which the PIN changes. Any phone can
  /// make up new identities, so a per-client limit alone would not stop
  /// guessing; with this, a guess succeeds with odds of about 1 in 100,000.
  static const int changePinAfterWrong = 10;

  final Map<String, SelectedDocument> _items = {};
  final Map<String, HostClient> _clients = {};
  final Queue<_PendingSend> _queue = Queue();
  int _active = 0;

  bool get isHosting => _items.isNotEmpty;
  String get shareName => _shareName;
  HostAccess get access => _access;

  /// The PIN to give people for a private share; null when public.
  String? get pin => isHosting ? _pin : null;
  int get itemCount => _items.length;
  int get totalBytes => _items.values.fold(
    0,
    (sum, d) => sum + (d.sizeBytes > 0 ? d.sizeBytes : 0),
  );

  /// Phones that browsed this host, most recent first.
  List<HostClient> get clients =>
      _clients.values.toList()
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  /// Fires whenever hosting, clients or their state change.
  Stream<void> get changes => _changes.stream;

  /// Hosts that stopped sharing while this phone was their client.
  Stream<String> get hostsEnded => _hostsEnded.stream;

  void startHosting(
    String name,
    List<SelectedDocument> documents, {
    HostAccess access = HostAccess.public,
  }) {
    if (documents.isEmpty) throw ArgumentError('Nothing to host');
    _shareName = name;
    _access = access;
    _pin = access == HostAccess.private ? _newPin() : null;
    _admitted.clear();
    _wrongTries.clear();
    _wrongTotal = 0;
    _items
      ..clear()
      ..addEntries([
        for (final d in documents.take(HostCatalog.maxItems))
          MapEntry(_newId(), d),
      ]);
    _clients.clear();
    _changed();
    onHostingChanged?.call(true);
  }

  /// Stops sharing: clients are told, queued downloads are dropped.
  /// Transfers already running finish (or are cancelled from their screen).
  Future<void> stopHosting() async {
    if (!isHosting) return;
    final told = _clients.keys.toList();
    _items.clear();
    // Clients still waiting in line will not be served now.
    for (final pending in _queue) {
      _setClient(pending.clientId, HostClientState.failed);
    }
    _queue.clear();
    _changed();
    onHostingChanged?.call(false);
    for (final id in told) {
      final session = sessionFor(id);
      if (session == null || !session.isEstablished) continue;
      try {
        await _send(
          session,
          PacketType.hostEnded,
          HostCatalogRequest(_newId()).toBytes(),
        );
      } catch (_) {}
    }
  }

  Future<void> _onCatalogRequest(
    SecureSession session,
    VayuPacket packet,
  ) async {
    final HostCatalogRequest request;
    try {
      request = HostCatalogRequest.fromBytes(packet.payload);
    } on FormatException {
      return;
    }
    if (isHosting && _access == HostAccess.private) {
      final locked = _checkPin(session, request);
      if (locked != null) {
        await _send(session, PacketType.hostCatalog, locked.toBytes());
        return;
      }
    }
    if (isHosting) _touch(session, HostClientState.browsing);
    final catalog = isHosting
        ? HostCatalog(
            access: _access,
            requestId: request.requestId,
            hosting: true,
            shareName: _shareName,
            items: [
              for (final MapEntry(key: id, value: d) in _items.entries)
                HostedItem(
                  itemId: id,
                  name: d.name,
                  sizeBytes: d.sizeBytes,
                  mimeType: d.mimeType,
                  folder: d.folder,
                ),
            ],
          )
        : HostCatalog(requestId: request.requestId, hosting: false);
    await _send(session, PacketType.hostCatalog, catalog.toBytes());
  }

  Future<void> _onDownloadRequest(
    SecureSession session,
    VayuPacket packet,
  ) async {
    final HostDownloadRequest request;
    try {
      request = HostDownloadRequest.fromBytes(packet.payload);
    } on FormatException {
      return;
    }
    Future<void> answer(HostDownloadResponse r) =>
        _send(session, PacketType.hostDownloadResponse, r.toBytes());

    if (!isHosting) {
      return answer(
        HostDownloadResponse(
          requestId: request.requestId,
          accepted: false,
          reason: HostDeclineReason.notHosting,
        ),
      );
    }
    if (_access == HostAccess.private &&
        !_admitted.contains(session.remoteDeviceId.toLowerCase())) {
      return answer(
        HostDownloadResponse(
          requestId: request.requestId,
          accepted: false,
          reason: HostDeclineReason.pinRequired,
        ),
      );
    }
    final docs = [for (final id in request.itemIds) ?_items[id]];
    if (docs.length != request.itemIds.length) {
      return answer(
        HostDownloadResponse(
          requestId: request.requestId,
          accepted: false,
          reason: HostDeclineReason.unknownItems,
        ),
      );
    }
    final clientId = session.remoteDeviceId;
    final name = nameOf(session) ?? 'Nearby phone';
    final queued = _active >= maxConcurrentClients;
    _touch(
      session,
      queued ? HostClientState.queued : HostClientState.downloading,
      files: docs.length,
    );
    _queue.add(_PendingSend(clientId, name, docs, request.ticketHex));
    await answer(
      HostDownloadResponse(
        requestId: request.requestId,
        accepted: true,
        queued: queued,
      ),
    );
    _pump();
  }

  void _pump() {
    while (_active < maxConcurrentClients && _queue.isNotEmpty) {
      final next = _queue.removeFirst();
      _active++;
      _setClient(next.clientId, HostClientState.downloading);
      sendToClient(
            clientDeviceId: next.clientId,
            clientName: next.clientName,
            documents: next.documents,
            ticketHex: next.ticketHex,
          )
          .then(
            (_) => _setClient(next.clientId, HostClientState.done),
            onError: (Object e) {
              AppLogger.warning('Host', 'Sending to a client failed: $e');
              _setClient(next.clientId, HostClientState.failed);
            },
          )
          .whenComplete(() {
            _active--;
            _pump();
          });
    }
  }

  /// Private share: null when [session]'s phone may browse (admitted now or
  /// before), else the locked catalog to answer with.
  HostCatalog? _checkPin(SecureSession session, HostCatalogRequest request) {
    final pin = request.pin;
    final id = session.remoteDeviceId.toLowerCase();
    if (_admitted.contains(id)) return null;
    HostCatalog locked(HostLock lock, {int? left}) => HostCatalog(
      requestId: request.requestId,
      hosting: true,
      shareName: _shareName,
      access: HostAccess.private,
      lock: lock,
      attemptsLeft: left,
    );
    final tries = _wrongTries[id] ?? 0;
    if (tries >= maxTriesPerClient) {
      _touch(session, HostClientState.blocked);
      return locked(HostLock.tooManyAttempts, left: 0);
    }
    if (pin == null) {
      _touch(session, HostClientState.waitingForPin);
      return locked(HostLock.pinRequired);
    }
    if (_sameDigits(pin, _pin ?? '')) {
      _admitted.add(id);
      return null;
    }
    _wrongTries[id] = tries + 1;
    _wrongTotal++;
    if (_wrongTotal >= changePinAfterWrong) {
      AppLogger.info('Host', 'Too many wrong PINs; the PIN changes');
      _pin = _newPin();
      _wrongTotal = 0;
    }
    final left = maxTriesPerClient - tries - 1;
    _touch(
      session,
      left > 0 ? HostClientState.wrongPin : HostClientState.blocked,
    );
    return locked(
      left > 0 ? HostLock.pinWrong : HostLock.tooManyAttempts,
      left: left,
    );
  }

  /// Compares in constant time, so timing does not reveal correct digits.
  static bool _sameDigits(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  String _newPin() =>
      List.generate(6, (_) => _random.nextInt(10).toString()).join();

  void _touch(SecureSession session, HostClientState state, {int? files}) {
    final id = session.remoteDeviceId.toLowerCase();
    final existing = _clients[id];
    _clients[id] = HostClient(
      deviceId: session.remoteDeviceId,
      name: nameOf(session) ?? existing?.name ?? 'Nearby phone',
      state: state,
      filesRequested: files ?? existing?.filesRequested ?? 0,
      lastSeen: DateTime.now(),
    );
    _changed();
  }

  void _setClient(String deviceId, HostClientState state) {
    final id = deviceId.toLowerCase();
    final c = _clients[id];
    if (c == null) return;
    _clients[id] = c.copyWith(state: state);
    _changed();
  }

  // ---------------------------------------------------------------- client

  final Map<String, Completer<HostCatalog>> _catalogs = {};
  final Map<String, Completer<HostDownloadResponse>> _downloads = {};
  final Map<String, String> _requestSessions = {};

  /// Items of the last catalog seen from each host, by item ID: what a
  /// download request is checked against when its files arrive.
  final Map<String, Map<String, HostedItem>> _seenItems = {};

  Future<SecureSession> _sessionWithHost(String hostDeviceId) async {
    var session = sessionFor(hostDeviceId);
    if (session == null || !session.isEstablished) {
      session = await connect(hostDeviceId);
    }
    if (!supportsHost(session)) {
      throw const HostUnavailableException(
        'That phone has an older Vayu without Host & Client',
      );
    }
    return session;
  }

  /// What [hostDeviceId] shares right now. A private host answers with a
  /// locked catalog until [pin] is right; once admitted, later calls need
  /// no PIN for as long as it keeps hosting.
  Future<HostCatalog> browse(String hostDeviceId, {String? pin}) async {
    final session = await _sessionWithHost(hostDeviceId);
    final id = _newId();
    final completer = Completer<HostCatalog>();
    _catalogs[id] = completer;
    _requestSessions[id] = session.sessionId;
    try {
      await _send(
        session,
        PacketType.hostCatalogRequest,
        HostCatalogRequest(id, pin: pin).toBytes(),
      );
      final catalog = await completer.future.timeout(
        answerTimeout,
        onTimeout: () =>
            throw const HostUnavailableException('The host did not answer'),
      );
      _seenItems[hostDeviceId.toLowerCase()] = {
        for (final i in catalog.items) i.itemId: i,
      };
      return catalog;
    } finally {
      _catalogs.remove(id);
      _requestSessions.remove(id);
    }
  }

  /// Asks the host for [itemIds]; the files then arrive as a batch.
  Future<HostDownloadResponse> download(
    String hostDeviceId,
    List<String> itemIds,
  ) async {
    final session = await _sessionWithHost(hostDeviceId);
    final id = _newId();
    final ticket = _newId() + _newId();
    // Ready before asking: the batch can follow the answer at once. Only
    // items seen in the host's catalog can be expected; anything else it
    // sends is not accepted without the user.
    final seen = _seenItems[hostDeviceId.toLowerCase()] ?? const {};
    expectFromHost(hostDeviceId, ticket, [
      for (final itemId in itemIds)
        if (seen[itemId] case final item?)
          BatchManifestEntry(
            fileName: item.name,
            sizeBytes: item.sizeBytes,
            mimeType: item.mimeType ?? 'application/octet-stream',
            folder: item.folder,
          ),
    ]);
    final completer = Completer<HostDownloadResponse>();
    _downloads[id] = completer;
    _requestSessions[id] = session.sessionId;
    try {
      await _send(
        session,
        PacketType.hostDownloadRequest,
        HostDownloadRequest(
          requestId: id,
          itemIds: itemIds,
          ticketHex: ticket,
        ).toBytes(),
      );
      return await completer.future.timeout(
        answerTimeout,
        onTimeout: () =>
            throw const HostUnavailableException('The host did not answer'),
      );
    } finally {
      _downloads.remove(id);
      _requestSessions.remove(id);
    }
  }

  void _onCatalog(SecureSession session, VayuPacket packet) {
    try {
      final catalog = HostCatalog.fromBytes(packet.payload);
      if (_requestSessions[catalog.requestId] != session.sessionId) return;
      _catalogs[catalog.requestId]?.complete(catalog);
    } on FormatException catch (e) {
      AppLogger.warning('Host', 'Ignoring malformed catalog: $e');
    }
  }

  void _onDownloadResponse(SecureSession session, VayuPacket packet) {
    try {
      final r = HostDownloadResponse.fromBytes(packet.payload);
      if (_requestSessions[r.requestId] != session.sessionId) return;
      _downloads[r.requestId]?.complete(r);
    } on FormatException catch (e) {
      AppLogger.warning('Host', 'Ignoring malformed answer: $e');
    }
  }

  // ---------------------------------------------------------------- shared

  void attach(Stream<({SecureSession session, VayuPacket packet})> packets) {
    _sub?.cancel();
    _sub = packets.listen((event) {
      final (:session, :packet) = event;
      switch (packet.packetType) {
        case PacketType.hostCatalogRequest:
          _onCatalogRequest(session, packet).catchError((Object e) {
            AppLogger.warning('Host', 'Catalog not sent: $e');
          });
        case PacketType.hostDownloadRequest:
          _onDownloadRequest(session, packet).catchError((Object e) {
            AppLogger.warning('Host', 'Download answer not sent: $e');
          });
        case PacketType.hostCatalog:
          _onCatalog(session, packet);
        case PacketType.hostDownloadResponse:
          _onDownloadResponse(session, packet);
        case PacketType.hostEnded:
          if (!_hostsEnded.isClosed) _hostsEnded.add(session.remoteDeviceId);
        default:
          break;
      }
    });
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _changes.close();
    await _hostsEnded.close();
  }

  Future<void> _send(
    SecureSession session,
    PacketType type,
    List<int> body,
  ) async {
    onActivity?.call(session);
    await session.sendEncryptedPacket(
      VayuPacket(
        packetType: type,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: parseIdTo16Bytes(localDeviceId()),
        destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
        payload: body is Uint8List ? body : Uint8List.fromList(body),
      ),
    );
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  String _newId() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class _PendingSend {
  final String clientId;
  final String clientName;
  final List<SelectedDocument> documents;
  final String ticketHex;

  _PendingSend(this.clientId, this.clientName, this.documents, this.ticketHex);
}
