import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/chat/chat_service.dart';
import 'package:vayu/core/chat/chat_store.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transfer/transfer_engine_impl.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/domain/chat/chat_payloads.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

/// Two phones over loopback with authenticated sessions, each with a chat.
class _Pair {
  final a = LocalDeviceIdentity.generate(
    displayName: 'Ana',
    platform: 'android',
  );
  final b = LocalDeviceIdentity.generate(
    displayName: 'Bo',
    platform: 'android',
  );
  final server = LanConnectionServer(requestedPort: 0);
  final storageA = InMemoryChatStorage();
  final storageB = InMemoryChatStorage();
  late final ConnectionManager managerA;
  late final ConnectionManager managerB;
  late final SecureSessionManager secureA;
  late final SecureSessionManager secureB;
  late final TransferEngineImpl engineA;
  late final TransferEngineImpl engineB;
  late final ChatService chatA;
  late final ChatService chatB;

  /// Whether A can open a session to B right now.
  bool reachable = true;

  Future<void> start() async {
    await server.start();
    managerA = ConnectionManager(localIdentity: a, displayName: () => 'Ana');
    managerB = ConnectionManager(localIdentity: b, displayName: () => 'Bo')
      ..registerLanServer(server);
    final crypto = CryptoService();
    secureA = SecureSessionManager(
      cryptoService: crypto,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: a,
    );
    secureB = SecureSessionManager(
      cryptoService: crypto,
      trustStore: PeerTrustStore(),
      secureKeyStore: InMemorySecureKeyStore(),
      localIdentity: b,
    );
    secureB.attachToConnectionManager(managerB);
    engineA = TransferEngineImpl(
      localDeviceId: a.idHex,
      secureSessionManager: secureA,
    );
    engineB = TransferEngineImpl(
      localDeviceId: b.idHex,
      secureSessionManager: secureB,
    );
    chatA = _chat(a, secureA, storageA, connect: (_) => _connectAtoB());
    chatB = _chat(
      b,
      secureB,
      storageB,
      connect: (_) async => throw const ChatUnavailableException('test'),
    );
    chatA.attach(
      packets: engineA.chatPackets,
      newSessions: secureA.secureSessions,
    );
    chatB.attach(
      packets: engineB.chatPackets,
      newSessions: secureB.secureSessions,
    );
  }

  ChatService _chat(
    LocalDeviceIdentity me,
    SecureSessionManager secure,
    ChatStorage storage, {
    required Future<SecureSession> Function(String) connect,
  }) => ChatService(
    localDeviceId: () => me.idHex,
    sessionFor: secure.getSessionForPeer,
    connect: connect,
    nameOf: (s) => s is SecureSessionImpl
        ? s.connectionSession.info.remoteDisplayName
        : null,
    supportsChat: (s) =>
        s is SecureSessionImpl &&
        s.connectionSession.info.remoteFeatures.contains(
          AppConstants.featureChat,
        ),
    storage: storage,
  );

  Future<SecureSession> _connectAtoB() async {
    if (!reachable) throw const ChatUnavailableException('not nearby');
    return secureA.secureOutboundConnection(
      await managerA.connectToLanPeer(
        remoteAddress: '127.0.0.1',
        remotePort: server.boundPort,
      ),
    );
  }

  Future<void> dispose() async {
    await chatA.dispose();
    await chatB.dispose();
    await engineA.dispose();
    await engineB.dispose();
    await secureA.dispose();
    await secureB.dispose();
    await managerA.dispose();
    await managerB.dispose();
    await server.stop();
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

void main() {
  test('a first message is a request on the receiving phone', () async {
    final pair = _Pair();
    await pair.start();
    try {
      final sent = await pair.chatA.send(
        deviceId: pair.b.idHex,
        peerName: 'Bo',
        text: 'Hi Bo',
      );
      expect(sent.state, MessageState.sent);

      // Sender: a normal chat at once.
      expect(pair.chatA.chats.single.peerName, 'Bo');
      expect(pair.chatA.requests, isEmpty);

      // Receiver: a message request, not a chat yet.
      await _until(() => pair.chatB.requests.isNotEmpty);
      final request = pair.chatB.requests.single;
      expect(request.peerName, 'Ana');
      expect(request.messages.single.text, 'Hi Bo');
      expect(pair.chatB.chats, isEmpty);

      // The sender learns it arrived.
      await _until(
        () =>
            pair.chatA.chats.single.messages.single.state ==
            MessageState.delivered,
      );
    } finally {
      await pair.dispose();
    }
  });

  test(
    'opening the request makes it a chat and sends a read receipt',
    () async {
      final pair = _Pair();
      await pair.start();
      try {
        await pair.chatA.send(
          deviceId: pair.b.idHex,
          peerName: 'Bo',
          text: 'Hi',
        );
        await _until(() => pair.chatB.requests.isNotEmpty);

        await pair.chatB.open(pair.a.idHex);
        expect(pair.chatB.requests, isEmpty);
        expect(pair.chatB.chats.single.unread, 0);

        await _until(
          () =>
              pair.chatA.chats.single.messages.single.state ==
              MessageState.read,
        );
      } finally {
        await pair.dispose();
      }
    },
  );

  test('requests are capped: a new one beyond the limit drops the oldest, '
      'accepted chats are kept', () async {
    final pair = _Pair();
    await pair.start();
    try {
      String id(int i) => i.toRadixString(16).padLeft(32, '0');
      Conversation request(int i) => Conversation(
        peerDeviceId: id(i),
        peerName: 'Stranger $i',
        accepted: false,
        messages: [
          ChatMessage(
            id: id(i),
            fromMe: false,
            text: 'hello $i',
            sentAt: DateTime.fromMillisecondsSinceEpoch(1000 + i),
            state: MessageState.delivered,
          ),
        ],
      );
      await pair.storageB.save([
        for (var i = 1; i <= ChatService.maxRequests; i++) request(i),
        Conversation(
          peerDeviceId: id(999),
          peerName: 'Friend',
          accepted: true,
          messages: [
            ChatMessage(
              id: id(999),
              fromMe: true,
              text: 'old chat',
              sentAt: DateTime.fromMillisecondsSinceEpoch(1),
              state: MessageState.read,
            ),
          ],
        ),
      ]);
      await pair.chatB.load();
      expect(pair.chatB.requests.length, ChatService.maxRequests);

      await pair.chatA.send(deviceId: pair.b.idHex, peerName: 'Bo', text: 'Hi');
      await _until(() => pair.chatB.requests.any((c) => c.peerName == 'Ana'));
      expect(pair.chatB.requests.length, ChatService.maxRequests);
      // The oldest request went; the accepted chat stayed.
      expect(pair.chatB.conversationWith(id(1)), isNull);
      expect(pair.chatB.conversationWith(id(2)), isNotNull);
      expect(pair.chatB.chats.single.peerName, 'Friend');
    } finally {
      await pair.dispose();
    }
  });

  test('a request left unopened never sends a read receipt', () async {
    final pair = _Pair();
    await pair.start();
    try {
      await pair.chatA.send(deviceId: pair.b.idHex, peerName: 'Bo', text: 'Hi');
      await _until(
        () =>
            pair.chatA.chats.single.messages.single.state ==
            MessageState.delivered,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        pair.chatA.chats.single.messages.single.state,
        MessageState.delivered,
      );
    } finally {
      await pair.dispose();
    }
  });

  test('replying also accepts the request', () async {
    final pair = _Pair();
    await pair.start();
    try {
      await pair.chatA.send(deviceId: pair.b.idHex, peerName: 'Bo', text: 'Hi');
      await _until(() => pair.chatB.requests.isNotEmpty);
      await pair.chatB.send(
        deviceId: pair.a.idHex,
        peerName: 'Ana',
        text: 'Hello',
      );
      expect(pair.chatB.requests, isEmpty);
      expect(pair.chatB.chats.single.messages.map((m) => m.text), [
        'Hi',
        'Hello',
      ]);
      await _until(() => pair.chatA.chats.single.messages.length == 2);
      expect(pair.chatA.chats.single.messages.last.fromMe, isFalse);
    } finally {
      await pair.dispose();
    }
  });

  test(
    'unreachable: kept as failed, sent when the phone connects again',
    () async {
      final pair = _Pair();
      await pair.start();
      try {
        pair.reachable = false;
        await expectLater(
          pair.chatA.send(
            deviceId: pair.b.idHex,
            peerName: 'Bo',
            text: 'Later',
          ),
          throwsA(isA<ChatUnavailableException>()),
        );
        expect(
          pair.chatA.chats.single.messages.single.state,
          MessageState.failed,
        );

        // The phones meet again: the failed message goes out by itself.
        pair.reachable = true;
        await pair._connectAtoB();
        await _until(() => pair.chatB.requests.isNotEmpty);
        expect(pair.chatB.requests.single.messages.single.text, 'Later');
      } finally {
        await pair.dispose();
      }
    },
  );

  test(
    'conversations survive a restart; a cut-off send reads as failed',
    () async {
      final storage = InMemoryChatStorage([
        Conversation(
          peerDeviceId: 'ab' * 16,
          peerName: 'Bo',
          accepted: true,
          messages: [
            ChatMessage(
              id: 'cd' * 16,
              fromMe: true,
              text: 'Hi',
              sentAt: DateTime(2026, 10, 18),
              state: MessageState.delivered,
            ),
          ],
        ),
      ]);
      // Saved while "sending" (app closed mid-send).
      final raw = (await storage.load()).single.toJson();
      (raw['messages'] as List).add({
        'id': 'ef' * 16,
        'me': true,
        'text': 'Cut off',
        'at': DateTime(2026, 10, 18, 1).millisecondsSinceEpoch,
        'state': 'sending',
      });
      final reloaded = Conversation.tryFromJson(raw)!;
      expect(reloaded.messages.last.state, MessageState.failed);

      final chat = ChatService(
        localDeviceId: () => '00' * 16,
        sessionFor: (_) => null,
        connect: (_) async => throw const ChatUnavailableException('x'),
        nameOf: (_) => null,
        supportsChat: (_) => true,
        storage: storage,
      );
      await chat.load();
      expect(chat.chats.single.messages.single.text, 'Hi');
      await chat.dispose();
    },
  );

  group('wire format', () {
    test('messages and receipts round-trip; bad input is rejected', () {
      final msg = ChatMessagePayload.fromBytes(
        ChatMessagePayload(
          id: '12' * 16,
          text: 'Hello',
          sentAt: DateTime(2026),
        ).toBytes(),
      );
      expect(msg.text, 'Hello');
      final ack = ChatAckPayload.fromBytes(
        ChatAckPayload(ids: ['12' * 16], receipt: ChatReceipt.read).toBytes(),
      );
      expect(ack.receipt, ChatReceipt.read);

      expect(
        () => ChatMessagePayload.fromBytes(
          ChatMessagePayload(
            id: 'nothex',
            text: 'x',
            sentAt: DateTime(2026),
          ).toBytes(),
        ),
        throwsFormatException,
      );
      expect(
        () => ChatMessagePayload.fromBytes(
          ChatMessagePayload(
            id: '12' * 16,
            text: 'x' * (ChatMessagePayload.maxLength + 1),
            sentAt: DateTime(2026),
          ).toBytes(),
        ),
        throwsFormatException,
      );
    });
  });
}
