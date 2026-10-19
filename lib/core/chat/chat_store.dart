import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/security/local_data_sealer.dart';
import 'package:vayu/domain/chat/chat_models.dart';

/// Where conversations are kept between app starts.
abstract class ChatStorage {
  Future<List<Conversation>> load();
  Future<void> save(List<Conversation> conversations);
}

/// Tests and desktop: nothing survives a restart.
class InMemoryChatStorage implements ChatStorage {
  List<Conversation> _saved;

  InMemoryChatStorage([List<Conversation>? initial])
    : _saved = List.of(initial ?? const []);

  @override
  Future<List<Conversation>> load() async => List.of(_saved);

  @override
  Future<void> save(List<Conversation> conversations) async =>
      _saved = List.of(conversations);
}

/// Conversations in app-private storage (never shared storage), sealed by
/// [sealer] so the file is unreadable without this phone's Keystore key,
/// and replaced atomically so a crash while saving cannot lose them.
///
/// [legacyPlainFile] is the unencrypted `chats.json` of earlier builds: it
/// is read once if no sealed file exists, then sealed and deleted.
class FileChatStorage implements ChatStorage {
  final File file;
  final LocalDataSealer sealer;
  final File? legacyPlainFile;

  /// Binds the sealed blob to this use (a blob sealed for anything else
  /// does not open as chats).
  static final Uint8List _aad = Uint8List.fromList(
    utf8.encode('vayu-chats-v1'),
  );

  FileChatStorage(this.file, {required this.sealer, this.legacyPlainFile});

  @override
  Future<List<Conversation>> load() async {
    try {
      if (await file.exists()) {
        final plain = await sealer.open(await file.readAsBytes(), aad: _aad);
        return _decode(utf8.decode(plain));
      }
      final legacy = legacyPlainFile;
      if (legacy != null && await legacy.exists()) {
        final conversations = _decode(await legacy.readAsString());
        await save(conversations);
        await legacy.delete();
        AppLogger.info('ChatStore', 'Chat history moved to encrypted storage');
        return conversations;
      }
      return [];
    } catch (e) {
      // A key lost after a reinstall or restore cannot be recovered; the
      // history is gone and the next save starts a new file.
      AppLogger.warning('ChatStore', 'Chat file unreadable: $e');
      return [];
    }
  }

  static List<Conversation> _decode(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['version'] != 1) return [];
    final entries = decoded['conversations'];
    if (entries is! List) return [];
    return [for (final e in entries) ?Conversation.tryFromJson(e)];
  }

  @override
  Future<void> save(List<Conversation> conversations) async {
    final payload = utf8.encode(
      jsonEncode({
        'version': 1,
        'conversations': [for (final c in conversations) c.toJson()],
      }),
    );
    final sealed = await sealer.seal(payload, aad: _aad);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(file.path);
  }
}
