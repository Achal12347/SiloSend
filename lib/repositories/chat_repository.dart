import 'dart:async';

import 'package:silosend/models/message.dart';
import 'package:silosend/services/chat/chat_service.dart';

/// Abstract repository for chat operations.
abstract class ChatRepository {
  Future<void> sendMessage({
    required String text,
    required String peerId,
    required String senderId,
    required String senderName,
  });

  Future<void> sendTypingIndicator({
    required String peerId,
    required String senderId,
    required String senderName,
    required bool isTyping,
  });

  Stream<Message> get messages;
  Stream<String> get typingIndicators;

  void startListening();
  void stopListening();
  void dispose();
}

/// Concrete implementation using the P2P chat service.
class P2pChatRepository implements ChatRepository {
  final ChatService _chatService;

  P2pChatRepository({required this._chatService});

  @override
  Future<void> sendMessage({
    required String text,
    required String peerId,
    required String senderId,
    required String senderName,
  }) async {
    await _chatService.sendMessage(
      text: text,
      peerId: peerId,
      senderId: senderId,
      senderName: senderName,
    );
  }

  @override
  Future<void> sendTypingIndicator({
    required String peerId,
    required String senderId,
    required String senderName,
    required bool isTyping,
  }) async {
    await _chatService.sendTypingIndicator(
      peerId: peerId,
      senderId: senderId,
      senderName: senderName,
      isTyping: isTyping,
    );
  }

  @override
  Stream<Message> get messages => _chatService.messages;

  @override
  Stream<String> get typingIndicators => _chatService.typingIndicators;

  @override
  void startListening() => _chatService.startListening();

  @override
  void stopListening() => _chatService.stopListening();

  @override
  void dispose() => _chatService.dispose();
}
