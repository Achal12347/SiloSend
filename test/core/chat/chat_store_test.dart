import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/chat/chat_store.dart';
import 'package:vayu/core/security/local_data_sealer.dart';
import 'package:vayu/domain/chat/chat_models.dart';

/// Real AES-GCM with a key held in memory, standing in for the Keystore.
class _Sealer implements LocalDataSealer {
  final SecretKey key;
  final AesGcm _aes = AesGcm.with256bits();

  _Sealer(List<int> keyBytes) : key = SecretKey(keyBytes);

  @override
  Future<Uint8List> seal(Uint8List data, {required Uint8List aad}) async {
    final box = await _aes.encrypt(data, secretKey: key, aad: aad);
    return Uint8List.fromList(box.concatenation());
  }

  @override
  Future<Uint8List> open(Uint8List blob, {required Uint8List aad}) async {
    final box = SecretBox.fromConcatenation(
      blob,
      nonceLength: 12,
      macLength: 16,
    );
    return Uint8List.fromList(
      await _aes.decrypt(box, secretKey: key, aad: aad),
    );
  }
}

Conversation _chat(String text) => Conversation(
  peerDeviceId: 'a1' * 16,
  peerName: 'Friend',
  accepted: true,
  messages: [
    ChatMessage(
      id: 'b2' * 16,
      fromMe: true,
      text: text,
      sentAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      state: MessageState.delivered,
    ),
  ],
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('vayu_chats_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'messages are never written in plain text and read back intact',
    () async {
      final file = File('${dir.path}/chats.sealed');
      final store = FileChatStorage(file, sealer: _Sealer(List.filled(32, 7)));
      await store.save([_chat('meet at the north gate')]);

      final raw = file.readAsBytesSync();
      expect(latin1.decode(raw).contains('north gate'), isFalse);
      expect(latin1.decode(raw).contains('Friend'), isFalse);

      final loaded = await store.load();
      expect(loaded.single.messages.single.text, 'meet at the north gate');
      expect(loaded.single.peerName, 'Friend');
    },
  );

  test('an old plain chats.json is sealed and then deleted', () async {
    final legacy = File('${dir.path}/chats.json')
      ..writeAsStringSync(
        jsonEncode({
          'version': 1,
          'conversations': [_chat('old message').toJson()],
        }),
      );
    final file = File('${dir.path}/chats.sealed');
    final store = FileChatStorage(
      file,
      sealer: _Sealer(List.filled(32, 7)),
      legacyPlainFile: legacy,
    );

    final loaded = await store.load();
    expect(loaded.single.messages.single.text, 'old message');
    expect(legacy.existsSync(), isFalse);
    expect(file.existsSync(), isTrue);
    expect((await store.load()).single.messages.single.text, 'old message');
  });

  test(
    'a file sealed with another key opens as no history, not a crash',
    () async {
      final file = File('${dir.path}/chats.sealed');
      await FileChatStorage(
        file,
        sealer: _Sealer(List.filled(32, 1)),
      ).save([_chat('secret')]);
      final other = FileChatStorage(file, sealer: _Sealer(List.filled(32, 2)));
      expect(await other.load(), isEmpty);
    },
  );
}
