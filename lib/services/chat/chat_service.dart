import 'dart:async';
import 'dart:convert';

import 'package:silosend/models/message.dart';
import 'package:silosend/services/connection/p2p_connection_service.dart';
import 'package:uuid/uuid.dart';

class ChatService {
  final P2pConnectionService _connectionService;
  final Uuid _uuid = const Uuid();
  StreamSubscription<String>? _incomingSubscription;
  final StreamController<Message> _messageController =
      StreamController<Message>.broadcast();
  final StreamController<String> _typingController =
      StreamController<String>.broadcast();

  ChatService({required this._connectionService});

  /// Start listening for incoming chat messages over the P2P connection.
  void startListening() {
    _incomingSubscription?.cancel();
    _incomingSubscription = _connectionService.streamReceivedTexts().listen(
      _handleIncoming,
    );
  }

  void stopListening() {
    _incomingSubscription?.cancel();
    _incomingSubscription = null;
  }

  void _handleIncoming(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final type = json['type'] as String? ?? 'text';

      if (type == 'typing') {
        final peerId = json['senderId'] as String? ?? '';
        _typingController.add(peerId);
      } else if (type == 'text' || type == 'message') {
        final message = Message.fromJson(json, isMe: false);
        _messageController.add(message);
      }
    } catch (_) {
      // If it's not valid JSON, treat as plain text message
      final message = Message(
        id: _uuid.v4(),
        text: raw,
        senderId: 'remote',
        senderName: 'Peer',
        timestamp: DateTime.now(),
        isMe: false,
      );
      _messageController.add(message);
    }
  }

  /// Send a text message to a specific peer.
  Future<void> sendMessage({
    required String text,
    required String peerId,
    required String senderId,
    required String senderName,
  }) async {
    final message = Message(
      id: _uuid.v4(),
      text: text,
      senderId: senderId,
      senderName: senderName,
      timestamp: DateTime.now(),
      isMe: true,
      status: MessageStatus.sending,
    );

    final payload = jsonEncode({...message.toJson(), 'type': 'text'});

    await _connectionService.sendTextToPeer(payload, peerId);

    // Update status to sent after successful send
    _messageController.add(message.copyWith(status: MessageStatus.sent));
  }

  /// Send a typing indicator to a specific peer.
  Future<void> sendTypingIndicator({
    required String peerId,
    required String senderId,
    required String senderName,
    required bool isTyping,
  }) async {
    final payload = jsonEncode({
      'type': 'typing',
      'senderId': senderId,
      'senderName': senderName,
      'isTyping': isTyping,
      'timestamp': DateTime.now().toIso8601String(),
    });

    await _connectionService.sendTextToPeer(payload, peerId);
  }

  /// Stream of incoming messages from peers.
  Stream<Message> get messages => _messageController.stream;

  /// Stream of typing indicators (peerId emitted when they start typing).
  Stream<String> get typingIndicators => _typingController.stream;

  void dispose() {
    stopListening();
    _messageController.close();
    _typingController.close();
  }
}
