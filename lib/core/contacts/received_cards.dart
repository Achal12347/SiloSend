import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/contacts/contact_card.dart';

/// How a card reached this phone.
enum ReceivedVia { tap, nearby, scan }

/// A contact card someone gave this phone, kept until the user deletes it.
class ReceivedCard {
  final String id;
  final String name;
  final String? organization;

  /// The original vCard in app-private storage.
  final String path;

  /// Who sent it, when known (a nearby phone's name).
  final String? fromName;
  final ReceivedVia via;
  final DateTime receivedAt;

  const ReceivedCard({
    required this.id,
    required this.name,
    required this.path,
    required this.via,
    required this.receivedAt,
    this.organization,
    this.fromName,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (organization != null) 'organization': organization,
    'path': path,
    if (fromName != null) 'fromName': fromName,
    'via': via.name,
    'receivedAt': receivedAt.toIso8601String(),
  };

  static ReceivedCard? tryFromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return ReceivedCard(
        id: json['id'] as String,
        name: json['name'] as String,
        organization: json['organization'] as String?,
        path: json['path'] as String,
        fromName: json['fromName'] as String?,
        via: ReceivedVia.values.firstWhere(
          (v) => v.name == json['via'],
          orElse: () => ReceivedVia.nearby,
        ),
        receivedAt: DateTime.parse(json['receivedAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

abstract class ReceivedCardsStorage {
  Future<List<ReceivedCard>> load();
  Future<void> save(List<ReceivedCard> cards);
}

class InMemoryReceivedCardsStorage implements ReceivedCardsStorage {
  List<ReceivedCard> _cards = [];

  @override
  Future<List<ReceivedCard>> load() async => List.of(_cards);

  @override
  Future<void> save(List<ReceivedCard> cards) async => _cards = List.of(cards);
}

/// JSON index with atomic replace; a damaged index loads empty (the card
/// files themselves are untouched).
class FileReceivedCardsStorage implements ReceivedCardsStorage {
  final File file;

  FileReceivedCardsStorage(this.file);

  @override
  Future<List<ReceivedCard>> load() async {
    try {
      if (!await file.exists()) return [];
      final json = jsonDecode(await file.readAsString());
      if (json is! List) return [];
      return [for (final entry in json) ?ReceivedCard.tryFromJson(entry)];
    } catch (e) {
      AppLogger.warning('ReceivedCards', 'Index unreadable: $e');
      return [];
    }
  }

  @override
  Future<void> save(List<ReceivedCard> cards) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode([for (final c in cards) c.toJson()]),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

/// Every card received by tap or from a nearby phone, newest first.
///
/// A tapped card is kept the moment it arrives, so closing the sheet never
/// loses it; saving it to the phone's contacts is a separate, optional step.
class ReceivedCards {
  final ReceivedCardsStorage storage;

  /// Folder for card files (app-private).
  final Future<String> Function() directory;

  final List<ReceivedCard> _cards = [];
  final StreamController<List<ReceivedCard>> _changes =
      StreamController<List<ReceivedCard>>.broadcast();
  Future<void> _saving = Future<void>.value();

  ReceivedCards({required this.storage, required this.directory});

  List<ReceivedCard> get all => List.unmodifiable(_cards);
  Stream<List<ReceivedCard>> get changes => _changes.stream;

  /// Loads the index, dropping entries whose file is gone.
  Future<void> load() async {
    final loaded = await storage.load();
    final kept = <ReceivedCard>[];
    for (final card in loaded) {
      if (await File(card.path).exists()) kept.add(card);
    }
    kept.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    _cards
      ..clear()
      ..addAll(kept);
    if (kept.length != loaded.length) await _persist();
    _emit();
  }

  /// Stores a card that arrived as bytes (a tap). The same card tapped again
  /// within a minute is not stored twice.
  Future<ReceivedCard?> addBytes(
    Uint8List vcard, {
    required ReceivedVia via,
    String? fromName,
  }) async {
    final parsed = ContactCard.tryParse(vcard);
    if (parsed == null) return null;
    final recent = _cards.where(
      (c) =>
          c.name == parsed.displayName &&
          DateTime.now().difference(c.receivedAt) < const Duration(minutes: 1),
    );
    for (final card in recent) {
      try {
        final existing = await File(card.path).readAsBytes();
        if (_sameBytes(existing, vcard)) return card;
      } catch (_) {}
    }
    final dir = await directory();
    await Directory(dir).create(recursive: true);
    final path = await _uniquePath(
      dir,
      ContactCard.fileNameFor(parsed.displayName),
    );
    await File(path).writeAsBytes(vcard, flush: true);
    return _record(parsed, path, via: via, fromName: fromName);
  }

  /// Records a card file that is already saved (received from a nearby phone).
  Future<ReceivedCard?> addFile(
    String path, {
    required ReceivedVia via,
    String? fromName,
  }) async {
    try {
      final parsed = ContactCard.tryParse(await File(path).readAsBytes());
      if (parsed == null) return null;
      return await _record(parsed, path, via: via, fromName: fromName);
    } catch (e) {
      AppLogger.warning('ReceivedCards', 'Could not read a received card: $e');
      return null;
    }
  }

  /// The card's contents, or null when its file is gone.
  Future<ContactCard?> read(ReceivedCard card) async {
    try {
      return ContactCard.tryParse(await File(card.path).readAsBytes());
    } catch (_) {
      return null;
    }
  }

  /// Deletes the card and its file.
  Future<void> remove(String id) async {
    final index = _cards.indexWhere((c) => c.id == id);
    if (index < 0) return;
    final card = _cards.removeAt(index);
    try {
      final file = File(card.path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    await _persist();
    _emit();
  }

  Future<ReceivedCard> _record(
    ContactCard parsed,
    String path, {
    required ReceivedVia via,
    String? fromName,
  }) async {
    _cards.removeWhere((c) => c.path == path);
    final card = ReceivedCard(
      id: _newId(),
      name: parsed.displayName,
      organization: parsed.organization,
      path: path,
      fromName: fromName,
      via: via,
      receivedAt: DateTime.now(),
    );
    _cards.insert(0, card);
    await _persist();
    _emit();
    return card;
  }

  Future<void> _persist() {
    final snapshot = List<ReceivedCard>.of(_cards);
    _saving = _saving.then((_) => storage.save(snapshot)).catchError((
      Object e,
    ) {
      AppLogger.warning('ReceivedCards', 'Saving the index failed: $e');
    });
    return _saving;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(all);
  }

  void dispose() => _changes.close();

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<String> _uniquePath(String dir, String fileName) async {
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    var candidate = '$dir/$fileName';
    var n = 1;
    while (await File(candidate).exists()) {
      candidate = '$dir/$base ($n)$ext';
      n++;
    }
    return candidate;
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(
      8,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
