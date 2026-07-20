enum MessageStatus { sending, sent, delivered, read }

enum MessageType { text, typing }

class Message {
  final String id;
  final String text;
  final String senderId;
  final String senderName;
  final DateTime timestamp;
  final MessageStatus status;
  final bool isMe;
  final MessageType type;

  const Message({
    required this.id,
    required this.text,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    required this.isMe,
    this.status = MessageStatus.sent,
    this.type = MessageType.text,
  });

  Message copyWith({
    String? id,
    String? text,
    String? senderId,
    String? senderName,
    DateTime? timestamp,
    MessageStatus? status,
    bool? isMe,
    MessageType? type,
  }) {
    return Message(
      id: id ?? this.id,
      text: text ?? this.text,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      isMe: isMe ?? this.isMe,
      type: type ?? this.type,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'senderId': senderId,
    'senderName': senderName,
    'timestamp': timestamp.toIso8601String(),
    'status': status.name,
    'type': type.name,
  };

  factory Message.fromJson(Map<String, dynamic> json, {required bool isMe}) {
    return Message(
      id: json['id'] as String,
      text: json['text'] as String? ?? '',
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String? ?? 'Unknown',
      timestamp: DateTime.parse(json['timestamp'] as String),
      status: MessageStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => MessageStatus.sent,
      ),
      isMe: isMe,
      type: MessageType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MessageType.text,
      ),
    );
  }
}
