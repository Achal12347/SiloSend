import 'dart:convert';
import 'dart:io';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';

/// Where the user's own card is kept (app-private, never backed up).
abstract class MyCardStore {
  Future<VayuCard?> load();
  Future<void> save(VayuCard card);
}

class InMemoryMyCardStore implements MyCardStore {
  VayuCard? _card;

  InMemoryMyCardStore([this._card]);

  @override
  Future<VayuCard?> load() async => _card;

  @override
  Future<void> save(VayuCard card) async => _card = card;
}

/// JSON file with atomic replace.
class FileMyCardStore implements MyCardStore {
  final File file;

  FileMyCardStore(this.file);

  @override
  Future<VayuCard?> load() async {
    try {
      if (!await file.exists()) return null;
      return VayuCard.tryFromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      AppLogger.warning('MyCardStore', 'Card file unreadable: $e');
      return null;
    }
  }

  @override
  Future<void> save(VayuCard card) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(card.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}
