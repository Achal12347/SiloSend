import 'dart:convert';
import 'dart:typed_data';

final RegExp _id = RegExp(r'^[0-9a-f]{32}$');

Map<String, dynamic> _object(Uint8List bytes, String what) {
  final json = jsonDecode(utf8.decode(bytes));
  if (json is! Map<String, dynamic>) {
    throw FormatException('$what is not an object');
  }
  return json;
}

String _requestId(Map<String, dynamic> json, String what) {
  final id = json['id'];
  if (id is! String || !_id.hasMatch(id)) {
    throw FormatException('$what has no valid id');
  }
  return id;
}

/// One file a host shares. [itemId] is the host's own handle for it; the
/// client never learns where the file lives on the host.
class HostedItem {
  final String itemId;
  final String name;
  final int sizeBytes;
  final String? mimeType;

  /// Folder path inside a shared folder ("Trip/Day 1"), if any.
  final String? folder;

  const HostedItem({
    required this.itemId,
    required this.name,
    required this.sizeBytes,
    this.mimeType,
    this.folder,
  });

  Map<String, Object?> toJson() => {
    'i': itemId,
    'n': name,
    's': sizeBytes,
    if (mimeType != null) 'm': mimeType,
    if (folder != null) 'f': folder,
  };

  static HostedItem fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Item is not an object');
    final id = json['i'], name = json['n'], size = json['s'];
    if (id is! String || !_id.hasMatch(id)) {
      throw const FormatException('Item has no valid id');
    }
    if (name is! String || name.isEmpty || name.length > 255) {
      throw const FormatException('Item has no valid name');
    }
    if (size is! int || size < 0) {
      throw const FormatException('Item has no valid size');
    }
    final mime = json['m'], folder = json['f'];
    return HostedItem(
      itemId: id,
      name: name,
      sizeBytes: size,
      mimeType: mime is String ? mime : null,
      folder: folder is String ? folder : null,
    );
  }
}

/// Who may browse and download from a host.
enum HostAccess {
  /// Any nearby Vayu phone.
  public,

  /// Only phones that entered the 6-digit PIN shown on the host.
  private,
}

/// Why a private host showed no items.
enum HostLock { pinRequired, pinWrong, tooManyAttempts }

/// Valid PIN format: exactly 6 digits.
final RegExp hostPinFormat = RegExp(r'^[0-9]{6}$');

/// Client asks what a host shares (packet 0x50). [pin] only for a private
/// host; it travels inside the encrypted session.
class HostCatalogRequest {
  final String requestId;
  final String? pin;
  const HostCatalogRequest(this.requestId, {this.pin});

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(jsonEncode({'id': requestId, if (pin != null) 'pin': pin})),
  );

  static HostCatalogRequest fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'Catalog request');
    final pin = json['pin'];
    if (pin != null && (pin is! String || !hostPinFormat.hasMatch(pin))) {
      throw const FormatException('Catalog request has no valid PIN');
    }
    return HostCatalogRequest(
      _requestId(json, 'Catalog request'),
      pin: pin as String?,
    );
  }
}

/// What the host shares, or that it is not hosting (packet 0x51).
class HostCatalog {
  /// Most items one catalog lists.
  static const int maxItems = 2000;

  final String requestId;
  final bool hosting;
  final String shareName;
  final List<HostedItem> items;
  final HostAccess access;

  /// Set when a private host withheld its items (no PIN, wrong PIN).
  final HostLock? lock;

  /// Wrong PINs this client may still try (with [HostLock.pinWrong]).
  final int? attemptsLeft;

  const HostCatalog({
    required this.requestId,
    required this.hosting,
    this.shareName = '',
    this.items = const [],
    this.access = HostAccess.public,
    this.lock,
    this.attemptsLeft,
  });

  bool get isLocked => lock != null;

  int get totalBytes => items.fold(0, (sum, i) => sum + i.sizeBytes);

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'id': requestId,
        'on': hosting,
        if (hosting) 'name': shareName,
        if (hosting) 'items': [for (final i in items) i.toJson()],
        if (hosting) 'access': access.name,
        if (lock != null) 'lock': lock!.name,
        if (attemptsLeft != null) 'left': attemptsLeft,
      }),
    ),
  );

  static HostCatalog fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'Catalog');
    final id = _requestId(json, 'Catalog');
    if (json['on'] != true) return HostCatalog(requestId: id, hosting: false);
    final items = json['items'];
    if (items is! List || items.length > maxItems) {
      throw const FormatException('Catalog has no valid items');
    }
    final name = json['name'];
    final left = json['left'];
    return HostCatalog(
      requestId: id,
      hosting: true,
      shareName: name is String ? name : '',
      items: [for (final i in items) HostedItem.fromJson(i)],
      // Older hosts send no access: they are open to all.
      access: json['access'] == 'private'
          ? HostAccess.private
          : HostAccess.public,
      lock: HostLock.values.where((l) => l.name == json['lock']).firstOrNull,
      attemptsLeft: left is int && left >= 0 ? left : null,
    );
  }
}

/// Client asks for some items (packet 0x52). [ticketHex] is a one-time
/// secret: the host's batch carries a proof made from it, so this client
/// accepts those files, and only those, without a prompt.
class HostDownloadRequest {
  final String requestId;
  final List<String> itemIds;
  final String ticketHex;

  const HostDownloadRequest({
    required this.requestId,
    required this.itemIds,
    required this.ticketHex,
  });

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({'id': requestId, 'items': itemIds, 't': ticketHex}),
    ),
  );

  static HostDownloadRequest fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'Download request');
    final id = _requestId(json, 'Download request');
    final items = json['items'];
    final ticket = json['t'];
    if (items is! List ||
        items.isEmpty ||
        items.length > HostCatalog.maxItems ||
        items.any((i) => i is! String || !_id.hasMatch(i))) {
      throw const FormatException('Download request has no valid items');
    }
    if (ticket is! String || !RegExp(r'^[0-9a-f]{32,64}$').hasMatch(ticket)) {
      throw const FormatException('Download request has no valid ticket');
    }
    return HostDownloadRequest(
      requestId: id,
      itemIds: items.cast<String>(),
      ticketHex: ticket,
    );
  }
}

/// Why a host did not start sending.
enum HostDeclineReason {
  notHosting,
  unknownItems,
  busy,

  /// A private host: this client has not entered the right PIN.
  pinRequired,
}

/// Host answers a download request (packet 0x53). When accepted, the files
/// follow as an ordinary batch transfer; when [queued], once a slot frees.
class HostDownloadResponse {
  final String requestId;
  final bool accepted;
  final bool queued;
  final HostDeclineReason? reason;

  const HostDownloadResponse({
    required this.requestId,
    required this.accepted,
    this.queued = false,
    this.reason,
  });

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'id': requestId,
        'ok': accepted,
        if (queued) 'q': true,
        if (reason != null) 'r': reason!.name,
      }),
    ),
  );

  static HostDownloadResponse fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'Download answer');
    return HostDownloadResponse(
      requestId: _requestId(json, 'Download answer'),
      accepted: json['ok'] == true,
      queued: json['q'] == true,
      reason: HostDeclineReason.values
          .where((r) => r.name == json['r'])
          .firstOrNull,
    );
  }
}
