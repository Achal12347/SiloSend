import 'package:vayu/domain/transfer/batch_payloads.dart';

/// Why a consent grant exists. Only [userPrompt] is created today; the others
/// are reserved for TapSend, Rooms and trusted-device auto-accept.
enum ConsentSource { userPrompt, tapSend, roomPolicy, trustedDevice }

/// Receiver-side permission to accept the files of one batch from one sender
/// without asking again.
///
/// A grant is keyed by the sender's stable device ID (taken from the
/// authenticated session, never a display name) and the batch ID. Each
/// manifest entry can be used by one file at a time; an entry is freed again
/// if that file fails, so the sender can retry it, and is spent for good once
/// the file completes.
class ConsentGrant {
  final String senderDeviceId;
  final String batchId;
  final List<BatchManifestEntry> entries;
  final ConsentSource source;
  DateTime expiresAt;

  final Set<int> _inUse = {};
  final Set<int> _spent = {};

  ConsentGrant({
    required this.senderDeviceId,
    required this.batchId,
    required this.entries,
    required this.source,
    required this.expiresAt,
  });

  bool get isExhausted => _spent.length >= entries.length;
}

/// Holds consent grants and decides, on the receiving side, whether an
/// incoming file is covered by one.
class ConsentRegistry {
  /// A grant expires after this long without any file activity.
  final Duration idleLifetime;
  final DateTime Function() _now;

  final Map<String, ConsentGrant> _grants = {};

  ConsentRegistry({
    this.idleLifetime = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  static String _key(String sender, String batchId) =>
      '${sender.toLowerCase()}|${batchId.toLowerCase()}';

  /// Records that the user (or another [source]) approved [entries] from
  /// [senderDeviceId] under [batchId].
  ConsentGrant grant({
    required String senderDeviceId,
    required String batchId,
    required List<BatchManifestEntry> entries,
    ConsentSource source = ConsentSource.userPrompt,
  }) {
    _purgeExpired();
    final grant = ConsentGrant(
      senderDeviceId: senderDeviceId.toLowerCase(),
      batchId: batchId.toLowerCase(),
      entries: List.unmodifiable(entries),
      source: source,
      expiresAt: _now().add(idleLifetime),
    );
    _grants[_key(senderDeviceId, batchId)] = grant;
    return grant;
  }

  /// Claims manifest entry [index] for an incoming file. Returns true only
  /// when an unexpired grant from this exact sender and batch covers it, the
  /// file matches the entry, and the entry is not already in use or spent.
  bool claim({
    required String senderDeviceId,
    required String batchId,
    required int index,
    required String fileName,
    required int sizeBytes,
    required String mimeType,
  }) {
    _purgeExpired();
    final grant = _grants[_key(senderDeviceId, batchId)];
    if (grant == null) return false;
    if (index < 0 || index >= grant.entries.length) return false;
    if (grant._inUse.contains(index) || grant._spent.contains(index)) {
      return false;
    }
    if (!grant.entries[index].matches(
      fileName: fileName,
      sizeBytes: sizeBytes,
      mimeType: mimeType,
    )) {
      return false;
    }
    grant._inUse.add(index);
    grant.expiresAt = _now().add(idleLifetime);
    return true;
  }

  /// Reports how a claimed file ended. A completed file spends its entry; a
  /// failed one frees it so the sender may retry within the grant.
  void settle({
    required String senderDeviceId,
    required String batchId,
    required int index,
    required bool completed,
  }) {
    final key = _key(senderDeviceId, batchId);
    final grant = _grants[key];
    if (grant == null) return;
    grant._inUse.remove(index);
    if (completed) grant._spent.add(index);
    grant.expiresAt = _now().add(idleLifetime);
    if (grant.isExhausted) _grants.remove(key);
  }

  /// Removes every grant from [senderDeviceId] (for example when its key changed).
  void revokeSender(String senderDeviceId) {
    final sender = senderDeviceId.toLowerCase();
    _grants.removeWhere((_, g) => g.senderDeviceId == sender);
  }

  /// Whether an unexpired grant exists for this sender and batch.
  bool hasGrant(String senderDeviceId, String batchId) {
    _purgeExpired();
    return _grants.containsKey(_key(senderDeviceId, batchId));
  }

  void _purgeExpired() {
    final now = _now();
    _grants.removeWhere((_, g) => g._inUse.isEmpty && now.isAfter(g.expiresAt));
  }
}
