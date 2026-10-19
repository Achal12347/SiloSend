import 'dart:convert';
import 'dart:typed_data';

final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');

/// A text message (packet 0x20), only ever sent inside an authenticated,
/// encrypted session.
class ChatMessagePayload {
  /// Longest message accepted, in characters.
  static const int maxLength = 4000;

  final String id;
  final String text;
  final DateTime sentAt;

  const ChatMessagePayload({
    required this.id,
    required this.text,
    required this.sentAt,
  });

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({'id': id, 'text': text, 'at': sentAt.millisecondsSinceEpoch}),
    ),
  );

  static ChatMessagePayload fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Message is not an object');
    }
    final id = json['id'];
    final text = json['text'];
    final at = json['at'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('Message has no valid id');
    }
    if (text is! String || text.trim().isEmpty || text.length > maxLength) {
      throw const FormatException('Message text is empty or too long');
    }
    if (at is! int) throw const FormatException('Message has no time');
    return ChatMessagePayload(
      id: id,
      text: text,
      sentAt: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// What a receipt confirms.
enum ChatReceipt { delivered, read }

/// Receipt for messages (packet 0x21): arrived, or seen.
class ChatAckPayload {
  final List<String> ids;
  final ChatReceipt receipt;

  const ChatAckPayload({required this.ids, required this.receipt});

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(jsonEncode({'ids': ids, 'r': receipt.name})),
  );

  static ChatAckPayload fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Receipt is not an object');
    }
    final ids = json['ids'];
    if (ids is! List || ids.isEmpty || ids.length > 500) {
      throw const FormatException('Receipt has no message ids');
    }
    final valid = [
      for (final id in ids)
        if (id is String && _idPattern.hasMatch(id)) id,
    ];
    if (valid.length != ids.length) {
      throw const FormatException('Receipt has an invalid id');
    }
    final receipt = ChatReceipt.values.firstWhere(
      (r) => r.name == json['r'],
      orElse: () => throw const FormatException('Unknown receipt'),
    );
    return ChatAckPayload(ids: valid, receipt: receipt);
  }
}

Map<String, dynamic> _object(Uint8List bytes, String what) {
  final json = jsonDecode(utf8.decode(bytes));
  if (json is! Map<String, dynamic>) {
    throw FormatException('$what is not an object');
  }
  return json;
}

String _messageId(Map<String, dynamic> json, String what) {
  final id = json['id'];
  if (id is! String || !_idPattern.hasMatch(id)) {
    throw FormatException('$what has no valid id');
  }
  return id;
}

/// Files offered in a chat (packet 0x22). Only names, sizes and types; the
/// files follow as an ordinary transfer once the other phone accepts.
/// [withdrawn]: the sender can no longer send that offer.
class ChatFileOfferPayload {
  /// Most files one chat message offers.
  static const int maxFiles = 100;

  final String id;
  final List<({String name, int size, String? mime})> files;
  final DateTime sentAt;
  final bool withdrawn;

  const ChatFileOfferPayload({
    required this.id,
    required this.files,
    required this.sentAt,
    this.withdrawn = false,
  });

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'id': id,
        'at': sentAt.millisecondsSinceEpoch,
        if (withdrawn) 'gone': true,
        if (!withdrawn)
          'files': [
            for (final f in files)
              {'n': f.name, 's': f.size, if (f.mime != null) 'm': f.mime},
          ],
      }),
    ),
  );

  static ChatFileOfferPayload fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'File offer');
    final id = _messageId(json, 'File offer');
    final at = json['at'];
    if (at is! int) throw const FormatException('File offer has no time');
    final sentAt = DateTime.fromMillisecondsSinceEpoch(at);
    if (json['gone'] == true) {
      return ChatFileOfferPayload(
        id: id,
        files: const [],
        sentAt: sentAt,
        withdrawn: true,
      );
    }
    final raw = json['files'];
    if (raw is! List || raw.isEmpty || raw.length > maxFiles) {
      throw const FormatException('File offer has no valid files');
    }
    final files = <({String name, int size, String? mime})>[];
    for (final f in raw) {
      if (f is! Map) throw const FormatException('File entry is not an object');
      final name = f['n'], size = f['s'], mime = f['m'];
      if (name is! String || name.isEmpty || name.length > 255) {
        throw const FormatException('File entry has no valid name');
      }
      if (size is! int || size < 0) {
        throw const FormatException('File entry has no valid size');
      }
      files.add((name: name, size: size, mime: mime is String ? mime : null));
    }
    return ChatFileOfferPayload(id: id, files: files, sentAt: sentAt);
  }
}

/// The receiver's answer to a file offer (packet 0x23). When [accepted],
/// [ticketHex] is a one-time secret: the sender's transfer proves it, so the
/// receiver takes exactly the offered files without a prompt.
class ChatFileAnswerPayload {
  final String id;
  final bool accepted;
  final String? ticketHex;

  const ChatFileAnswerPayload({
    required this.id,
    required this.accepted,
    this.ticketHex,
  });

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'id': id,
        'ok': accepted,
        if (ticketHex != null) 't': ticketHex,
      }),
    ),
  );

  static ChatFileAnswerPayload fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'File answer');
    final id = _messageId(json, 'File answer');
    final ok = json['ok'] == true;
    final ticket = json['t'];
    if (ok &&
        (ticket is! String || !RegExp(r'^[0-9a-f]{32,64}$').hasMatch(ticket))) {
      throw const FormatException('Accepted file answer has no valid ticket');
    }
    return ChatFileAnswerPayload(
      id: id,
      accepted: ok,
      ticketHex: ok ? ticket as String : null,
    );
  }
}
