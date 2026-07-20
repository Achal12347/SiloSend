import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/core/logging/app_logger.dart';
import 'package:silosend/models/message.dart';
import 'package:silosend/repositories/chat_repository.dart';
import 'package:silosend/services/chat/chat_service.dart';
import 'package:silosend/features/transfer/providers/connection_provider.dart';

enum ChatConnectionStatus { disconnected, connecting, connected, error }

class ChatState {
  final List<Message> messages;
  final String inputText;
  final bool isPeerTyping;
  final ChatConnectionStatus connectionStatus;
  final String? errorMessage;

  const ChatState({
    this.messages = const [],
    this.inputText = '',
    this.isPeerTyping = false,
    this.connectionStatus = ChatConnectionStatus.disconnected,
    this.errorMessage,
  });

  ChatState copyWith({
    List<Message>? messages,
    String? inputText,
    bool? isPeerTyping,
    ChatConnectionStatus? connectionStatus,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      inputText: inputText ?? this.inputText,
      isPeerTyping: isPeerTyping ?? this.isPeerTyping,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  final ChatRepository _repository;
  StreamSubscription<Message>? _messageSubscription;
  StreamSubscription<String>? _typingSubscription;
  Timer? _typingDebounceTimer;

  ChatNotifier({required this._repository}) : super(const ChatState()) {
    _startListening();
  }

  void _startListening() {
    _repository.startListening();

    _messageSubscription = _repository.messages.listen(_onIncomingMessage);
    _typingSubscription = _repository.typingIndicators.listen(
      _onTypingIndicator,
    );

    state = state.copyWith(connectionStatus: ChatConnectionStatus.connected);
  }

  void _onIncomingMessage(Message message) {
    state = state.copyWith(messages: [...state.messages, message]);
  }

  void _onTypingIndicator(String peerId) {
    state = state.copyWith(isPeerTyping: true);
    _typingDebounceTimer?.cancel();
    _typingDebounceTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        state = state.copyWith(isPeerTyping: false);
      }
    });
  }

  void updateInputText(String text) {
    state = state.copyWith(inputText: text, clearError: true);
  }

  Future<void> sendMessage({
    required String peerId,
    required String senderId,
    required String senderName,
  }) async {
    final text = state.inputText.trim();
    if (text.isEmpty) return;

    final message = Message(
      id: '',
      text: text,
      senderId: senderId,
      senderName: senderName,
      timestamp: DateTime.now(),
      isMe: true,
      status: MessageStatus.sending,
    );

    state = state.copyWith(
      messages: [...state.messages, message],
      inputText: '',
    );

    try {
      await _repository.sendMessage(
        text: text,
        peerId: peerId,
        senderId: senderId,
        senderName: senderName,
      );
    } catch (e) {
      AppLogger.error('Failed to send message', error: e);
      state = state.copyWith(
        errorMessage: 'Failed to send message. Try again.',
      );
    }
  }

  Future<void> sendTypingIndicator({
    required String peerId,
    required String senderId,
    required String senderName,
    required bool isTyping,
  }) async {
    try {
      await _repository.sendTypingIndicator(
        peerId: peerId,
        senderId: senderId,
        senderName: senderName,
        isTyping: isTyping,
      );
    } catch (_) {
      // Typing indicators are best-effort
    }
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _typingSubscription?.cancel();
    _typingDebounceTimer?.cancel();
    _repository.stopListening();
    super.dispose();
  }
}

// ── Providers ─────────────────────────────────────────────────────────────

final chatServiceProvider = Provider<ChatService>((ref) {
  final connectionService = ref.read(p2pConnectionServiceProvider);
  final service = ChatService(connectionService: connectionService);
  ref.onDispose(service.dispose);
  return service;
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final chatService = ref.read(chatServiceProvider);
  return P2pChatRepository(chatService: chatService);
});

final chatProvider = StateNotifierProvider.autoDispose<ChatNotifier, ChatState>(
  (ref) {
    final repository = ref.read(chatRepositoryProvider);
    return ChatNotifier(repository: repository);
  },
);
