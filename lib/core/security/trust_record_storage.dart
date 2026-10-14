import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/domain/security/trust_level.dart';

/// Persistence for [PeerTrustStore] records.
///
/// Records hold peers' public identity keys and trust levels, never secrets,
/// but they reveal which devices this phone has met, so they stay in
/// app-private storage and are excluded from Android backups.
abstract class TrustRecordStorage {
  Future<List<PeerTrustRecord>> load();
  Future<void> save(List<PeerTrustRecord> records);
}

/// JSON file storage with atomic replace, so a crash mid-write cannot corrupt
/// the store and silently reset every peer to first contact.
class FileTrustRecordStorage implements TrustRecordStorage {
  final File file;

  FileTrustRecordStorage(this.file);

  @override
  Future<List<PeerTrustRecord>> load() async {
    try {
      if (!await file.exists()) return [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) return [];
      final entries = decoded['peers'];
      if (entries is! List) return [];
      final records = <PeerTrustRecord>[];
      for (final entry in entries) {
        final record = _decode(entry);
        if (record != null) records.add(record);
      }
      return records;
    } catch (e) {
      AppLogger.warning('TrustRecordStorage', 'Trust store unreadable: $e');
      return [];
    }
  }

  @override
  Future<void> save(List<PeerTrustRecord> records) async {
    final payload = jsonEncode({
      'version': 1,
      'peers': records.map(_encode).toList(),
    });
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(file.path);
  }

  static Map<String, Object> _encode(PeerTrustRecord r) => {
    'deviceId': r.deviceIdHex,
    'identityPubKey': base64Encode(r.identityPubKey),
    'trustLevel': r.trustLevel.name,
    'firstSeen': r.firstSeen.toUtc().toIso8601String(),
    'lastSeen': r.lastSeen.toUtc().toIso8601String(),
  };

  static PeerTrustRecord? _decode(Object? raw) {
    if (raw is! Map) return null;
    try {
      final level = TrustLevel.values.firstWhere(
        (l) => l.name == raw['trustLevel'],
      );
      final key = Uint8List.fromList(
        base64Decode(raw['identityPubKey'] as String),
      );
      if (key.length != 32) return null;
      return PeerTrustRecord(
        deviceIdHex: (raw['deviceId'] as String).toLowerCase(),
        identityPubKey: key,
        trustLevel: level,
        firstSeen: DateTime.parse(raw['firstSeen'] as String),
        lastSeen: DateTime.parse(raw['lastSeen'] as String),
      );
    } catch (_) {
      return null; // Skip one malformed entry rather than discarding the store.
    }
  }
}
