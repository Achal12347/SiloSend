/// Where a message is on its way, as far as this phone knows.
enum MessageState {
  /// Being handed to a connection.
  sending,

  /// Handed to an encrypted session; the other phone has not confirmed yet.
  sent,

  /// The other phone confirmed it arrived.
  delivered,

  /// The other phone opened the conversation after it arrived.
  read,

  /// Could not be sent (no connection); can be sent again.
  failed;

  static MessageState parse(Object? value) => MessageState.values.firstWhere(
    (s) => s.name == value,
    orElse: () => MessageState.failed,
  );
}

/// Where the files of a file message are.
enum ChatFileState {
  /// Offered. Sender: waiting for the other phone to accept. Receiver: on
  /// hold until this user accepts (or arrived while the chat was open and
  /// is being accepted).
  offered,

  /// Receiver accepted; waiting for the files to start.
  accepted,
  transferring,

  /// All files arrived intact (receiver) or were confirmed (sender).
  done,
  declined,
  failed,

  /// The offer can no longer be fulfilled (the sender's app restarted).
  unavailable;

  static ChatFileState? parse(Object? value) =>
      ChatFileState.values.where((s) => s.name == value).firstOrNull;
}

/// One file in a file message.
class ChatFile {
  final String name;
  final int sizeBytes;
  final String? mimeType;

  /// Receiver: where it was saved, once received.
  final String? savedPath;

  const ChatFile({
    required this.name,
    required this.sizeBytes,
    this.mimeType,
    this.savedPath,
  });

  ChatFile withPath(String? path) => ChatFile(
    name: name,
    sizeBytes: sizeBytes,
    mimeType: mimeType,
    savedPath: path,
  );

  Map<String, Object?> toJson() => {
    'n': name,
    's': sizeBytes,
    if (mimeType != null) 'm': mimeType,
    if (savedPath != null) 'p': savedPath,
  };

  static ChatFile? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['n'], size = json['s'];
    if (name is! String || name.isEmpty || size is! int || size < 0) {
      return null;
    }
    final mime = json['m'], path = json['p'];
    return ChatFile(
      name: name,
      sizeBytes: size,
      mimeType: mime is String ? mime : null,
      savedPath: path is String ? path : null,
    );
  }
}

/// One message: text, or files. Only real messages exist here; nothing is
/// generated.
class ChatMessage {
  /// 32 hex characters, chosen by the sender.
  final String id;
  final bool fromMe;
  final String text;
  final DateTime sentAt;
  final MessageState state;

  /// Files sent in the chat (empty for a text message).
  final List<ChatFile> files;
  final ChatFileState? fileState;

  /// The transfer carrying the files, while it runs or after.
  final String? batchId;

  const ChatMessage({
    required this.id,
    required this.fromMe,
    required this.text,
    required this.sentAt,
    required this.state,
    this.files = const [],
    this.fileState,
    this.batchId,
  });

  bool get isFile => files.isNotEmpty;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  ChatMessage withState(MessageState next) => copyWith(state: next);

  ChatMessage copyWith({
    MessageState? state,
    List<ChatFile>? files,
    ChatFileState? fileState,
    String? batchId,
  }) => ChatMessage(
    id: id,
    fromMe: fromMe,
    text: text,
    sentAt: sentAt,
    state: state ?? this.state,
    files: files ?? this.files,
    fileState: fileState ?? this.fileState,
    batchId: batchId ?? this.batchId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'me': fromMe,
    'text': text,
    'at': sentAt.millisecondsSinceEpoch,
    'state': state.name,
    if (isFile) 'files': [for (final f in files) f.toJson()],
    if (fileState != null) 'fs': fileState!.name,
    if (batchId != null) 'batch': batchId,
  };

  static ChatMessage? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final text = json['text'];
    final at = json['at'];
    if (id is! String || text is! String || at is! int) return null;
    var state = MessageState.parse(json['state']);
    // A send cut off by closing the app did not happen.
    if (state == MessageState.sending) state = MessageState.failed;
    final rawFiles = json['files'];
    final files = rawFiles is List
        ? [for (final f in rawFiles) ?ChatFile.tryFromJson(f)]
        : const <ChatFile>[];
    final batch = json['batch'];
    return ChatMessage(
      id: id,
      fromMe: json['me'] == true,
      text: text,
      sentAt: DateTime.fromMillisecondsSinceEpoch(at),
      state: state,
      files: files,
      fileState: files.isEmpty ? null : ChatFileState.parse(json['fs']),
      batchId: batch is String ? batch : null,
    );
  }
}

/// All messages with one phone, oldest first.
///
/// A conversation started by the other phone is a message request until
/// this user opens it or replies (as in common messaging apps).
class Conversation {
  final String peerDeviceId;
  final String peerName;

  /// False while it is a message request.
  final bool accepted;
  final List<ChatMessage> messages;

  const Conversation({
    required this.peerDeviceId,
    required this.peerName,
    required this.accepted,
    required this.messages,
  });

  bool get isRequest => !accepted;

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  DateTime? get lastActivity => lastMessage?.sentAt;

  /// Incoming messages not opened yet.
  int get unread =>
      messages.where((m) => !m.fromMe && m.state != MessageState.read).length;

  Conversation copyWith({
    String? peerName,
    bool? accepted,
    List<ChatMessage>? messages,
  }) => Conversation(
    peerDeviceId: peerDeviceId,
    peerName: peerName ?? this.peerName,
    accepted: accepted ?? this.accepted,
    messages: messages ?? this.messages,
  );

  Map<String, Object?> toJson() => {
    'peer': peerDeviceId,
    'name': peerName,
    'accepted': accepted,
    'messages': [for (final m in messages) m.toJson()],
  };

  static Conversation? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final peer = json['peer'];
    final name = json['name'];
    final messages = json['messages'];
    if (peer is! String || name is! String || messages is! List) return null;
    return Conversation(
      peerDeviceId: peer,
      peerName: name,
      accepted: json['accepted'] == true,
      messages: [for (final m in messages) ?ChatMessage.tryFromJson(m)],
    );
  }
}
