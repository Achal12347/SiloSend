import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/features/chat/providers/chat_provider.dart';
import 'package:silosend/models/message.dart' as models;

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _wasTyping = false;

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final state = ref.read(chatProvider);
    if (state.inputText.trim().isEmpty) return;

    // Use placeholder peer/sender IDs — real values come from connection state
    await ref
        .read(chatProvider.notifier)
        .sendMessage(
          peerId: 'connected-peer',
          senderId: 'local-user',
          senderName: 'Me',
        );

    _scrollToBottom();
  }

  void _onTextChanged(String text) {
    ref.read(chatProvider.notifier).updateInputText(text);

    final isTyping = text.isNotEmpty;
    if (isTyping != _wasTyping) {
      _wasTyping = isTyping;
      ref
          .read(chatProvider.notifier)
          .sendTypingIndicator(
            peerId: 'connected-peer',
            senderId: 'local-user',
            senderName: 'Me',
            isTyping: isTyping,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat'),
        actions: [
          IconButton(
            tooltip: 'Connection info',
            onPressed: () => _showConnectionInfo(context, chatState),
            icon: Icon(
              chatState.connectionStatus == ChatConnectionStatus.connected
                  ? Icons.wifi
                  : Icons.wifi_off,
              color:
                  chatState.connectionStatus == ChatConnectionStatus.connected
                  ? Colors.green
                  : theme.colorScheme.error,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Connection status bar
          if (chatState.connectionStatus != ChatConnectionStatus.connected)
            _ConnectionBanner(status: chatState.connectionStatus),
          // Messages list
          Expanded(
            child: chatState.messages.isEmpty
                ? _EmptyState(theme: theme)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    itemCount: chatState.messages.length,
                    itemBuilder: (context, index) {
                      final message = chatState.messages[index];
                      return _ChatBubble(message: message);
                    },
                  ),
          ),
          // Typing indicator
          if (chatState.isPeerTyping)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'typing...',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          // Error banner
          if (chatState.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                chatState.errorMessage!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
          const Divider(height: 1),
          // Input bar
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    onChanged: _onTextChanged,
                    decoration: InputDecoration(
                      hintText:
                          chatState.connectionStatus ==
                              ChatConnectionStatus.connected
                          ? 'Type a message'
                          : 'Not connected',
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Send',
                  onPressed:
                      chatState.connectionStatus ==
                          ChatConnectionStatus.connected
                      ? _sendMessage
                      : null,
                  icon: Icon(Icons.send, color: theme.colorScheme.primary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showConnectionInfo(BuildContext context, ChatState state) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connection'),
        content: Text(
          'Status: ${state.connectionStatus.name}\n'
          'Messages: ${state.messages.length}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ThemeData theme;
  const _EmptyState({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 48,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text('No messages yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Messages you send and receive will appear here.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  final ChatConnectionStatus status;
  const _ConnectionBanner({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color bg, String text) = switch (status) {
      ChatConnectionStatus.disconnected => (
        theme.colorScheme.errorContainer,
        'Not connected to any device',
      ),
      ChatConnectionStatus.connecting => (
        theme.colorScheme.secondaryContainer,
        'Connecting...',
      ),
      ChatConnectionStatus.error => (
        theme.colorScheme.errorContainer,
        'Connection error',
      ),
      ChatConnectionStatus.connected => (Colors.green.shade100, 'Connected'),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: bg,
      child: Text(text, style: theme.textTheme.bodySmall),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final models.Message message;

  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final alignment = message.isMe
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final bgColor = message.isMe
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHigh;
    final textColor = message.isMe
        ? theme.colorScheme.onPrimaryContainer
        : theme.textTheme.bodyMedium?.color;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: message.isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Align(
            alignment: alignment,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.text.isNotEmpty)
                      Text(message.text, style: TextStyle(color: textColor)),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(message.timestamp),
                          style: TextStyle(
                            color: textColor?.withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                        ),
                        if (message.isMe) ...[
                          const SizedBox(width: 4),
                          Icon(
                            _statusIcon(message.status),
                            size: 14,
                            color: textColor?.withValues(alpha: 0.6),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  IconData _statusIcon(models.MessageStatus status) {
    return switch (status) {
      models.MessageStatus.sending => Icons.access_time,
      models.MessageStatus.sent => Icons.check,
      models.MessageStatus.delivered => Icons.done_all,
      models.MessageStatus.read => Icons.done_all,
    };
  }
}
