import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/chat/chat_store.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
// Same addressing helper the transfer engine uses for every packet.
import 'package:vayu/core/transfer/transfer_task_impl.dart'
    show parseIdTo16Bytes;
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/domain/chat/chat_payloads.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';

/// The other phone cannot be reached to deliver a message.
class ChatUnavailableException implements Exception {
  final String message;
  const ChatUnavailableException(this.message);

  @override
  String toString() => 'ChatUnavailableException: $message';
}

/// What chat needs from the transfer engine to carry files. Files never
/// travel inside chat packets: the chat carries an offer, and the files go
/// as an ordinary verified transfer once the other phone accepts.
abstract class ChatFileTransport {
  /// Sender: sends [documents] to [peerDeviceId] as one batch proving
  /// [ticketHex]; [onBatch] gets its ID as soon as it exists. Completes when
  /// the batch has finished.
  Future<void> send({
    required String peerDeviceId,
    required List<SelectedDocument> documents,
    required String ticketHex,
    required void Function(String batchId) onBatch,
  });

  /// Receiver: accept, without a prompt, a batch from [peerDeviceId] that
  /// proves [ticketHex] and holds exactly [files].
  void expect({
    required String peerDeviceId,
    required String ticketHex,
    required List<ChatFile> files,
    required String messageId,
  });

  /// Batches that arrived for an [expect]ation.
  Stream<({String messageId, String batchId})> get arrived;

  /// How a batch ended (with saved paths on the receiver), or null while it
  /// still runs or is unknown.
  ({bool ok, List<String?> paths})? outcome(String batchId);

  /// Fires when any transfer changes.
  Stream<void> get changes;
}

/// One-to-one messages over Vayu's existing encrypted sessions.
///
/// No networking of its own: messages and receipts are packets 0x20/0x21
/// inside the same authenticated sessions as files, routed here by the
/// transfer engine. A conversation started by the other phone is a message
/// request until this user opens it or replies. Receipts: "delivered" when
/// a message arrives, "read" once the conversation is opened (never for a
/// request still unopened).
///
/// Someone this user has not accepted reaches them only while the app is on
/// screen: what they send meanwhile waits in memory, without a notification
/// or a receipt, until the app is opened. Accepted chats arrive at any time.
class ChatService {
  final String Function() localDeviceId;

  /// An established session with the device, or null.
  final SecureSession? Function(String deviceId) sessionFor;

  /// Opens a session with the device (nearby list, or remembered from a
  /// code or tap). Throws when it cannot be reached.
  final Future<SecureSession> Function(String deviceId) connect;

  /// The other phone's display name for a session, if known.
  final String? Function(SecureSession session) nameOf;

  /// Whether the other phone understands chat (`chat-v1`).
  final bool Function(SecureSession session) supportsChat;

  /// Whether the other phone takes files in chats (`chat-files-v1`).
  final bool Function(SecureSession session) supportsChatFiles;

  /// Carries files; null where transfers are unavailable (files fail).
  ChatFileTransport? files;

  final ChatStorage storage;

  /// Told when a message or receipt goes out on a session (keeps it open
  /// while the chat is in use).
  void Function(SecureSession session)? onActivity;

  /// Called for a newly received message when its conversation is not open.
  final Future<void> Function(String peerName)? onIncomingMessage;

  /// Whether this app is on screen.
  final bool Function() isInForeground;

  /// Messages kept per conversation (oldest dropped first).
  static const int maxMessagesPerConversation = 1000;

  /// Unopened requests kept; a new one beyond this drops the oldest. Any
  /// phone can make up a new identity, so requests must not grow without
  /// end. Messages in a request are limited further.
  static const int maxRequests = 50;
  static const int maxMessagesPerRequest = 100;

  /// Messages from people not yet accepted, kept until the app is opened.
  /// Any phone can make up new identities, so this cannot grow without end.
  static const int maxHeld = 200;

  final Map<String, Conversation> _byPeer = {};
  final List<({SecureSession session, VayuPacket packet})> _held = [];
  bool _replayingHeld = false;
  final StreamController<List<Conversation>> _changes =
      StreamController<List<Conversation>>.broadcast();
  final Random _random = Random.secure();
  Future<void> _saving = Future.value();
  StreamSubscription<({SecureSession session, VayuPacket packet})>? _packets;
  StreamSubscription<SecureSession>? _sessions;

  ChatService({
    required this.localDeviceId,
    required this.sessionFor,
    required this.connect,
    required this.nameOf,
    required this.supportsChat,
    this.supportsChatFiles = _noFiles,
    required this.storage,
    this.files,
    this.onIncomingMessage,
    this.isInForeground = _alwaysForeground,
  });

  static bool _noFiles(SecureSession _) => false;
  static bool _alwaysForeground() => true;

  /// Sender side: the documents of offers still waiting, by message ID.
  /// Kept in memory only: after a restart the offer is answered "no longer
  /// available".
  final Map<String, ({String peer, List<SelectedDocument> documents})>
  _outgoing = {};

  /// The conversation on screen now (lower-case key), if any. Files offered
  /// while it is on screen are accepted at once; others wait on hold.
  String? _visiblePeer;

  StreamSubscription<({String messageId, String batchId})>? _arrivedSub;
  StreamSubscription<void>? _transfersSub;

  Future<void> load() async {
    _byPeer
      ..clear()
      ..addEntries([
        for (final c in await storage.load())
          MapEntry(_key(c.peerDeviceId), _afterRestart(c)),
      ]);
    _emit(persist: false);
  }

  /// File transfers do not survive a restart: offers this phone made can no
  /// longer be sent, and transfers that were running ended.
  static Conversation _afterRestart(Conversation c) => c.copyWith(
    messages: [
      for (final m in c.messages)
        switch ((m.fromMe, m.fileState)) {
          (true, ChatFileState.offered) => m.copyWith(
            fileState: ChatFileState.unavailable,
          ),
          (_, ChatFileState.transferring) || (false, ChatFileState.accepted) =>
            m.copyWith(fileState: ChatFileState.failed),
          _ => m,
        },
    ],
  );

  /// Starts handling chat packets and resending messages that failed when
  /// a device connects again.
  void attach({
    required Stream<({SecureSession session, VayuPacket packet})> packets,
    required Stream<SecureSession> newSessions,
  }) {
    _packets?.cancel();
    _packets = packets.listen(_onPacket);
    _sessions?.cancel();
    _sessions = newSessions.listen(_resendFailed);
    final transport = files;
    _arrivedSub?.cancel();
    _transfersSub?.cancel();
    if (transport != null) {
      _arrivedSub = transport.arrived.listen(_onFilesArrived);
      _transfersSub = transport.changes.listen((_) => _checkTransfers());
    }
  }

  void _onPacket(({SecureSession session, VayuPacket packet}) event) {
    final (:session, :packet) = event;
    switch (packet.packetType) {
      case PacketType.chatMessage:
      case PacketType.chatFileOffer:
        if (_mustWaitForApp(session.remoteDeviceId)) {
          if (_held.length >= maxHeld) _held.removeAt(0);
          _held.add(event);
        } else if (packet.packetType == PacketType.chatMessage) {
          _onMessage(session, packet);
        } else {
          _onFileOffer(session, packet);
        }
      case PacketType.chatDeliveryAck:
        _onAck(session, packet);
      case PacketType.chatFileAnswer:
        _onFileAnswer(session, packet).catchError((Object e) {
          AppLogger.warning('Chat', 'Handling a file answer failed: $e');
        });
      default:
        break;
    }
  }

  bool _mustWaitForApp(String deviceId) =>
      !isInForeground() && !(_byPeer[_key(deviceId)]?.accepted ?? false);

  /// The app is on screen again: what new people sent appears now, as message
  /// requests, and they get their delivery receipts.
  void appForegrounded() {
    if (_held.isEmpty) return;
    final waiting = List.of(_held);
    _held.clear();
    _replayingHeld = true;
    try {
      waiting.forEach(_onPacket);
    } finally {
      _replayingHeld = false;
    }
  }

  void _notifyIncoming(SecureSession session) {
    // Held messages appear while the user is looking at the app.
    if (_replayingHeld || _visiblePeer == _key(session.remoteDeviceId)) return;
    final peerName = nameOf(session) ?? 'Nearby phone';
    onIncomingMessage?.call(peerName).catchError((Object error) {
      AppLogger.info('Chat', 'Incoming notification was not shown: $error');
    });
  }

  Future<void> dispose() async {
    await _packets?.cancel();
    await _sessions?.cancel();
    await _arrivedSub?.cancel();
    await _transfersSub?.cancel();
    await _saving;
    await _changes.close();
  }

  // ------------------------------------------------------------------ reads

  Stream<List<Conversation>> get changes => _changes.stream;

  /// Accepted conversations, most recent first.
  List<Conversation> get chats =>
      _sorted(_byPeer.values.where((c) => c.accepted));

  /// Message requests, most recent first.
  List<Conversation> get requests =>
      _sorted(_byPeer.values.where((c) => c.isRequest));

  Conversation? conversationWith(String deviceId) => _byPeer[_key(deviceId)];

  /// Unread messages in accepted chats (requests are counted apart).
  int get unreadChats => chats.fold(0, (sum, c) => sum + c.unread);

  List<Conversation> _sorted(Iterable<Conversation> list) {
    final out = list.toList()
      ..sort((a, b) {
        final at = a.lastActivity, bt = b.lastActivity;
        if (at == null || bt == null) return at == null ? 1 : -1;
        return bt.compareTo(at);
      });
    return out;
  }

  // ----------------------------------------------------------------- writes

  /// Sends [text] to [deviceId]. The message is kept as failed (and sent
  /// again when the device connects) if it cannot go out now.
  Future<ChatMessage> send({
    required String deviceId,
    required String peerName,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw ArgumentError('Empty message');
    if (trimmed.length > ChatMessagePayload.maxLength) {
      throw ArgumentError(
        'Message longer than ${ChatMessagePayload.maxLength}',
      );
    }
    final message = ChatMessage(
      id: _newId(),
      fromMe: true,
      text: trimmed,
      sentAt: DateTime.now(),
      state: MessageState.sending,
    );
    // Writing back is how a request becomes a normal chat.
    final current = _byPeer[_key(deviceId)];
    _put(
      (current ??
              Conversation(
                peerDeviceId: deviceId,
                peerName: peerName,
                accepted: true,
                messages: const [],
              ))
          .copyWith(accepted: true, messages: [...?current?.messages, message]),
    );
    return _deliver(deviceId, message);
  }

  /// Sends a failed message again.
  Future<ChatMessage> retry(String deviceId, String messageId) async {
    final c = _byPeer[_key(deviceId)];
    final message = c?.messages.where((m) => m.id == messageId).firstOrNull;
    if (c == null || message == null || !message.fromMe) {
      throw StateError('No such message');
    }
    _setState(deviceId, messageId, MessageState.sending);
    return _deliver(deviceId, message.withState(MessageState.sending));
  }

  /// The user opened the conversation: a request becomes a chat, and
  /// unread messages are marked read (the sender gets a read receipt).
  Future<void> open(String deviceId) async {
    final c = _byPeer[_key(deviceId)];
    if (c == null) return;
    final unread = [
      for (final m in c.messages)
        if (!m.fromMe && m.state != MessageState.read) m.id,
    ];
    _put(
      c.copyWith(
        accepted: true,
        messages: [
          for (final m in c.messages)
            !m.fromMe && m.state != MessageState.read
                ? m.withState(MessageState.read)
                : m,
        ],
      ),
    );
    if (unread.isEmpty) return;
    final session = sessionFor(deviceId);
    if (session == null || !session.isEstablished) return;
    try {
      await _sendAck(session, unread, ChatReceipt.read);
    } catch (e) {
      AppLogger.info('Chat', 'Read receipt not sent: $e');
    }
  }

  /// The conversation with [deviceId] is on screen ([visible]) or left.
  void setVisible(String deviceId, bool visible) {
    final key = _key(deviceId);
    if (visible) {
      _visiblePeer = key;
    } else if (_visiblePeer == key) {
      _visiblePeer = null;
    }
  }

  /// Sends [documents] in the chat with [deviceId]: an offer the other phone
  /// accepts in the chat (at once while it has this chat open), then an
  /// ordinary verified transfer.
  Future<ChatMessage> sendFiles({
    required String deviceId,
    required String peerName,
    required List<SelectedDocument> documents,
  }) async {
    if (documents.isEmpty) throw ArgumentError('No files');
    if (documents.length > ChatFileOfferPayload.maxFiles) {
      throw ArgumentError(
        'At most ${ChatFileOfferPayload.maxFiles} files per message',
      );
    }
    if (documents.any((d) => d.sizeBytes < 0)) {
      throw ArgumentError('File size unknown');
    }
    final message = ChatMessage(
      id: _newId(),
      fromMe: true,
      text: '',
      sentAt: DateTime.now(),
      state: MessageState.sending,
      files: [
        for (final d in documents)
          ChatFile(name: d.name, sizeBytes: d.sizeBytes, mimeType: d.mimeType),
      ],
      fileState: ChatFileState.offered,
    );
    _outgoing[message.id] = (peer: _key(deviceId), documents: documents);
    final current = _byPeer[_key(deviceId)];
    _put(
      (current ??
              Conversation(
                peerDeviceId: deviceId,
                peerName: peerName,
                accepted: true,
                messages: const [],
              ))
          .copyWith(accepted: true, messages: [...?current?.messages, message]),
    );
    return _deliver(deviceId, message);
  }

  /// Accepts files the other phone offered: they arrive in the chat.
  Future<void> acceptFiles(String deviceId, String messageId) async {
    final m = _find(deviceId, messageId);
    if (m == null ||
        m.fromMe ||
        !m.isFile ||
        !(m.fileState == ChatFileState.offered ||
            m.fileState == ChatFileState.failed)) {
      return;
    }
    final transport = files;
    if (transport == null) {
      throw const ChatUnavailableException('Files cannot be received here');
    }
    final ticket = _newId() + _newId();
    // Ready before answering: the files can follow the answer at once.
    transport.expect(
      peerDeviceId: deviceId,
      ticketHex: ticket,
      files: m.files,
      messageId: m.id,
    );
    _update(
      deviceId,
      messageId,
      (x) => x.copyWith(fileState: ChatFileState.accepted),
    );
    try {
      await _answerOffer(deviceId, messageId, ticket);
    } catch (e) {
      _update(deviceId, messageId, (x) => x.copyWith(fileState: m.fileState));
      rethrow;
    }
  }

  /// Declines files the other phone offered (nothing is received).
  Future<void> declineFiles(String deviceId, String messageId) async {
    final m = _find(deviceId, messageId);
    if (m == null || m.fromMe || m.fileState != ChatFileState.offered) return;
    _update(
      deviceId,
      messageId,
      (x) => x.copyWith(fileState: ChatFileState.declined),
    );
    try {
      await _answerOffer(deviceId, messageId, null);
    } catch (e) {
      AppLogger.info('Chat', 'Decline not delivered: $e');
    }
  }

  Future<void> _answerOffer(
    String deviceId,
    String messageId,
    String? ticket,
  ) async {
    var session = sessionFor(deviceId);
    if (session == null || !session.isEstablished) {
      session = await connect(deviceId);
    }
    await session.sendEncryptedPacket(
      _packet(
        session,
        PacketType.chatFileAnswer,
        ChatFileAnswerPayload(
          id: messageId,
          accepted: ticket != null,
          ticketHex: ticket,
        ).toBytes(),
      ),
    );
    onActivity?.call(session);
  }

  VayuPacket _packet(SecureSession session, PacketType type, Uint8List body) =>
      VayuPacket(
        packetType: type,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: parseIdTo16Bytes(localDeviceId()),
        destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
        payload: body,
      );

  ChatMessage? _find(String deviceId, String messageId) =>
      _byPeer[_key(deviceId)]?.messages
          .where((m) => m.id == messageId)
          .firstOrNull;

  void _update(
    String deviceId,
    String messageId,
    ChatMessage Function(ChatMessage) change,
  ) {
    final c = _byPeer[_key(deviceId)];
    if (c == null) return;
    _put(
      c.copyWith(
        messages: [
          for (final m in c.messages) m.id == messageId ? change(m) : m,
        ],
      ),
    );
  }

  /// Receiver: files offered (or an offer withdrawn).
  void _onFileOffer(SecureSession session, VayuPacket packet) {
    final ChatFileOfferPayload offer;
    try {
      offer = ChatFileOfferPayload.fromBytes(packet.payload);
    } on FormatException catch (e) {
      AppLogger.warning('Chat', 'Ignoring malformed file offer: $e');
      return;
    }
    final peer = session.remoteDeviceId;
    if (offer.withdrawn) {
      final m = _find(peer, offer.id);
      if (m != null && !m.fromMe) {
        _update(
          peer,
          offer.id,
          (x) => x.copyWith(fileState: ChatFileState.unavailable),
        );
      }
      return;
    }
    final existing = _byPeer[_key(peer)];
    final duplicate =
        existing?.messages.any((m) => m.id == offer.id && !m.fromMe) ?? false;
    if (!duplicate) {
      if (existing == null) _makeRoomForRequest();
      final message = ChatMessage(
        id: offer.id,
        fromMe: false,
        text: '',
        sentAt: DateTime.now(),
        state: MessageState.delivered,
        files: [
          for (final f in offer.files)
            ChatFile(name: f.name, sizeBytes: f.size, mimeType: f.mime),
        ],
        fileState: ChatFileState.offered,
      );
      _put(
        (existing ??
                Conversation(
                  peerDeviceId: peer,
                  peerName: nameOf(session) ?? 'Nearby phone',
                  accepted: false,
                  messages: const [],
                ))
            .copyWith(
              peerName: nameOf(session),
              messages: [...?existing?.messages, message],
            ),
      );
      _notifyIncoming(session);
      // On screen in an accepted chat: take the files now. Otherwise they
      // wait on hold until this user accepts them in the chat.
      final c = _byPeer[_key(peer)];
      if (_visiblePeer == _key(peer) && (c?.accepted ?? false)) {
        acceptFiles(peer, offer.id).catchError((Object e) {
          AppLogger.info('Chat', 'Accepting files failed: $e');
        });
      }
    }
    _sendAck(session, [offer.id], ChatReceipt.delivered).catchError((Object e) {
      AppLogger.info('Chat', 'Delivery receipt not sent: $e');
    });
  }

  /// Sender: the other phone accepted or declined files.
  Future<void> _onFileAnswer(SecureSession session, VayuPacket packet) async {
    final ChatFileAnswerPayload answer;
    try {
      answer = ChatFileAnswerPayload.fromBytes(packet.payload);
    } on FormatException catch (e) {
      AppLogger.warning('Chat', 'Ignoring malformed file answer: $e');
      return;
    }
    final peer = session.remoteDeviceId;
    final m = _find(peer, answer.id);
    if (m == null || !m.fromMe || !m.isFile) return;
    if (!answer.accepted) {
      if (m.fileState == ChatFileState.offered) {
        _update(
          peer,
          m.id,
          (x) => x.copyWith(fileState: ChatFileState.declined),
        );
      }
      return;
    }
    final out = _outgoing[m.id];
    // Only the phone it was offered to may take it, once at a time.
    if (out == null || out.peer != _key(peer)) {
      _update(
        peer,
        m.id,
        (x) => x.copyWith(fileState: ChatFileState.unavailable),
      );
      await session.sendEncryptedPacket(
        _packet(
          session,
          PacketType.chatFileOffer,
          ChatFileOfferPayload(
            id: m.id,
            files: const [],
            sentAt: m.sentAt,
            withdrawn: true,
          ).toBytes(),
        ),
      );
      return;
    }
    if (m.fileState == ChatFileState.transferring) return;
    final transport = files;
    if (transport == null) return;
    _update(
      peer,
      m.id,
      (x) => x.copyWith(fileState: ChatFileState.transferring),
    );
    try {
      await transport.send(
        peerDeviceId: peer,
        documents: out.documents,
        ticketHex: answer.ticketHex!,
        onBatch: (batchId) =>
            _update(peer, m.id, (x) => x.copyWith(batchId: batchId)),
      );
    } catch (e) {
      AppLogger.warning('Chat', 'Sending chat files failed: $e');
      _update(peer, m.id, (x) => x.copyWith(fileState: ChatFileState.failed));
    }
    _checkTransfers();
  }

  void _onFilesArrived(({String messageId, String batchId}) event) {
    for (final c in _byPeer.values) {
      final m = c.messages.where((x) => x.id == event.messageId && !x.fromMe);
      if (m.isEmpty) continue;
      _update(
        c.peerDeviceId,
        event.messageId,
        (x) => x.copyWith(
          fileState: ChatFileState.transferring,
          batchId: event.batchId,
        ),
      );
      return;
    }
  }

  /// Records how file transfers in chats ended.
  void _checkTransfers() {
    final transport = files;
    if (transport == null) return;
    for (final c in _byPeer.values.toList()) {
      for (final m in c.messages) {
        final batch = m.batchId;
        if (batch == null || m.fileState != ChatFileState.transferring) {
          continue;
        }
        final end = transport.outcome(batch);
        if (end == null) continue;
        if (m.fromMe && end.ok) _outgoing.remove(m.id);
        _update(
          c.peerDeviceId,
          m.id,
          (x) => x.copyWith(
            fileState: end.ok ? ChatFileState.done : ChatFileState.failed,
            files: m.fromMe
                ? null
                : [
                    for (var i = 0; i < x.files.length; i++)
                      x.files[i].withPath(
                        i < end.paths.length ? end.paths[i] : null,
                      ),
                  ],
          ),
        );
      }
    }
  }

  /// Removes every conversation from this phone only (Your data). Files
  /// already received stay where they were saved.
  void deleteAll() {
    _held.clear();
    _byPeer.clear();
    _outgoing.clear();
    _emit();
  }

  /// Messages kept on this phone, in all conversations.
  int get messageCount =>
      _byPeer.values.fold(0, (sum, c) => sum + c.messages.length);

  /// Removes the conversation from this phone only.
  void delete(String deviceId) {
    _byPeer.remove(_key(deviceId));
    _emit();
  }

  // -------------------------------------------------------------- delivery

  Future<ChatMessage> _deliver(String deviceId, ChatMessage message) async {
    try {
      var session = sessionFor(deviceId);
      if (session == null || !session.isEstablished) {
        session = await connect(deviceId);
      }
      if (!supportsChat(session)) {
        throw const ChatUnavailableException(
          'The other phone has an older Vayu without chat',
        );
      }
      if (message.isFile && !supportsChatFiles(session)) {
        throw const ChatUnavailableException(
          'The other phone has an older Vayu without files in chats',
        );
      }
      await session.sendEncryptedPacket(
        message.isFile
            ? _packet(
                session,
                PacketType.chatFileOffer,
                ChatFileOfferPayload(
                  id: message.id,
                  files: [
                    for (final f in message.files)
                      (name: f.name, size: f.sizeBytes, mime: f.mimeType),
                  ],
                  sentAt: message.sentAt,
                ).toBytes(),
              )
            : VayuPacket(
                packetType: PacketType.chatMessage,
                packetId: DateTime.now().microsecondsSinceEpoch,
                sourceDeviceId: parseIdTo16Bytes(localDeviceId()),
                destinationDeviceId: parseIdTo16Bytes(deviceId),
                payload: ChatMessagePayload(
                  id: message.id,
                  text: message.text,
                  sentAt: message.sentAt,
                ).toBytes(),
              ),
      );
      onActivity?.call(session);
      return _setState(deviceId, message.id, MessageState.sent) ?? message;
    } catch (e) {
      AppLogger.info('Chat', 'Message not sent now: $e');
      _setState(deviceId, message.id, MessageState.failed);
      rethrow;
    }
  }

  /// A device connected again: send what failed before, oldest first.
  Future<void> _resendFailed(SecureSession session) async {
    final c = _byPeer[_key(session.remoteDeviceId)];
    if (c == null || !supportsChat(session)) return;
    for (final m in c.messages) {
      if (m.fromMe && m.state == MessageState.failed) {
        try {
          _setState(c.peerDeviceId, m.id, MessageState.sending);
          await _deliver(c.peerDeviceId, m.withState(MessageState.sending));
        } catch (_) {
          return; // Still unreachable; the rest stays failed.
        }
      }
    }
  }

  void _onMessage(SecureSession session, VayuPacket packet) {
    final ChatMessagePayload payload;
    try {
      payload = ChatMessagePayload.fromBytes(packet.payload);
    } on FormatException catch (e) {
      AppLogger.warning('Chat', 'Ignoring malformed message: $e');
      return;
    }
    final peer = session.remoteDeviceId;
    final existing = _byPeer[_key(peer)];
    // A resend of a message already here is only acknowledged again.
    final duplicate =
        existing?.messages.any((m) => m.id == payload.id && !m.fromMe) ?? false;
    if (!duplicate) {
      if (existing == null) _makeRoomForRequest();
      final message = ChatMessage(
        id: payload.id,
        fromMe: false,
        text: payload.text,
        // The arrival time orders the conversation; the sender's clock may
        // be wrong.
        sentAt: DateTime.now(),
        state: MessageState.delivered,
      );
      _put(
        (existing ??
                Conversation(
                  peerDeviceId: peer,
                  peerName: nameOf(session) ?? 'Nearby phone',
                  // Started by the other phone: a request until opened.
                  accepted: false,
                  messages: const [],
                ))
            .copyWith(
              peerName: nameOf(session),
              messages: [...?existing?.messages, message],
            ),
      );
      _notifyIncoming(session);
    }
    _sendAck(session, [payload.id], ChatReceipt.delivered).catchError((
      Object e,
    ) {
      AppLogger.info('Chat', 'Delivery receipt not sent: $e');
    });
  }

  void _onAck(SecureSession session, VayuPacket packet) {
    final ChatAckPayload ack;
    try {
      ack = ChatAckPayload.fromBytes(packet.payload);
    } on FormatException catch (e) {
      AppLogger.warning('Chat', 'Ignoring malformed receipt: $e');
      return;
    }
    final c = _byPeer[_key(session.remoteDeviceId)];
    if (c == null) return;
    final next = ack.receipt == ChatReceipt.read
        ? MessageState.read
        : MessageState.delivered;
    final ids = ack.ids.toSet();
    _put(
      c.copyWith(
        messages: [
          for (final m in c.messages)
            // Only this phone's own messages, and never backwards
            // (a late "delivered" after "read").
            m.fromMe && ids.contains(m.id) && _rank(next) > _rank(m.state)
                ? m.withState(next)
                : m,
        ],
      ),
    );
  }

  static int _rank(MessageState s) => switch (s) {
    MessageState.failed || MessageState.sending => 0,
    MessageState.sent => 1,
    MessageState.delivered => 2,
    MessageState.read => 3,
  };

  Future<void> _sendAck(
    SecureSession session,
    List<String> ids,
    ChatReceipt receipt,
  ) => session.sendEncryptedPacket(
    VayuPacket(
      packetType: PacketType.chatDeliveryAck,
      packetId: DateTime.now().microsecondsSinceEpoch,
      sourceDeviceId: parseIdTo16Bytes(localDeviceId()),
      destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
      payload: ChatAckPayload(ids: ids, receipt: receipt).toBytes(),
    ),
  );

  // ---------------------------------------------------------------- helpers

  ChatMessage? _setState(String deviceId, String id, MessageState state) {
    final c = _byPeer[_key(deviceId)];
    if (c == null) return null;
    ChatMessage? updated;
    _put(
      c.copyWith(
        messages: [
          for (final m in c.messages)
            if (m.id == id && m.fromMe) updated = m.withState(state) else m,
        ],
      ),
    );
    return updated;
  }

  /// Drops the oldest unopened request when the limit is reached.
  void _makeRoomForRequest() {
    final pending = requests;
    if (pending.length < maxRequests) return;
    _byPeer.remove(_key(pending.last.peerDeviceId));
  }

  void _put(Conversation c) {
    final limit = c.accepted
        ? maxMessagesPerConversation
        : maxMessagesPerRequest;
    final messages = c.messages.length > limit
        ? c.messages.sublist(c.messages.length - limit)
        : c.messages;
    _byPeer[_key(c.peerDeviceId)] = c.copyWith(messages: messages);
    _emit();
  }

  void _emit({bool persist = true}) {
    if (!_changes.isClosed) _changes.add(chats);
    if (!persist) return;
    final snapshot = _byPeer.values.toList();
    _saving = _saving.then((_) => storage.save(snapshot)).catchError((
      Object e,
    ) {
      AppLogger.warning('Chat', 'Saving chats failed: $e');
    });
  }

  static String _key(String deviceId) =>
      deviceId.replaceAll('-', '').toLowerCase();

  String _newId() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
