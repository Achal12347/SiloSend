import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/ui/chats/conversation_page.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/shell/primary_actions.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/peer_picker_sheet.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Chats tab: conversations with phones, newest first, and a link to
/// message requests (conversations other phones started).
class ChatsPage extends StatelessWidget {
  const ChatsPage({super.key});

  Future<void> _newChat(BuildContext context, AppContainer container) async {
    final peer = await pickNearbyPeer(
      context,
      container: container,
      title: 'New chat with',
    );
    if (peer == null || !context.mounted) return;
    await ConversationPage.open(
      context,
      container,
      peerDeviceId: peer.deviceId,
      peerName: peer.displayName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final container = AppScope.of(context);
    final chat = container.chatService;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('Chats'),
        actions: primaryAppBarActions(context, container),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newChat(context, container),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New chat'),
      ),
      body: SafeArea(
        child: StreamBuilder<List<Conversation>>(
          stream: chat.changes,
          builder: (context, _) {
            final chats = chat.chats;
            final requests = chat.requests;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
              children: [
                if (requests.isNotEmpty) ...[
                  Card(
                    child: ListTile(
                      onTap: () => RequestsPage.open(context, container),
                      leading: Icon(
                        Icons.mark_chat_unread_outlined,
                        color: VayuPalette.of(context).accent,
                      ),
                      title: const Text('Message requests'),
                      subtitle: Text(
                        requests.length == 1
                            ? '${requests.single.peerName} sent you a message'
                            : '${requests.length} people sent you messages',
                      ),
                      trailing: _CountBadge(count: requests.length),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (chats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 48, 16, 0),
                    child: Column(
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 44,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No chats yet',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Start one with a nearby phone. Messages are '
                          'encrypted and need no internet.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (var i = 0; i < chats.length; i++) ...[
                          if (i > 0) const Divider(indent: 72, endIndent: 16),
                          ConversationTile(
                            conversation: chats[i],
                            onTap: () => ConversationPage.open(
                              context,
                              container,
                              peerDeviceId: chats[i].peerDeviceId,
                              peerName: chats[i].peerName,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Conversations other phones started, waiting to be opened.
class RequestsPage extends StatelessWidget {
  final AppContainer container;

  const RequestsPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RequestsPage(container: container)),
      );

  @override
  Widget build(BuildContext context) {
    final chat = container.chatService;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Message requests')),
      body: SafeArea(
        child: StreamBuilder<List<Conversation>>(
          stream: chat.changes,
          builder: (context, _) {
            final requests = chat.requests;
            if (requests.isEmpty) {
              return Center(
                child: Text(
                  'No message requests.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(
                    'They will not see that you read their message until you '
                    'open the chat.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < requests.length; i++) ...[
                        if (i > 0) const Divider(indent: 72, endIndent: 16),
                        ConversationTile(
                          conversation: requests[i],
                          onTap: () => ConversationPage.open(
                            context,
                            container,
                            peerDeviceId: requests[i].peerDeviceId,
                            peerName: requests[i].peerName,
                          ),
                          onDelete: () => chat.delete(requests[i].peerDeviceId),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A conversation row: who, the last message, when, unread count.
class ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = conversation.lastMessage;
    final unread = conversation.unread;
    final body = last == null
        ? ''
        : last.isFile
        ? last.files.length == 1
              ? '📎 ${last.files.single.name}'
              : '📎 ${last.files.length} files'
        : last.text;
    final preview = last == null
        ? ''
        : last.fromMe
        ? 'You: $body'
        : body;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      leading: DeviceAvatar(
        name: conversation.peerName,
        seed: conversation.peerDeviceId,
      ),
      title: Text(
        conversation.peerName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: unread > 0 ? FontWeight.w700 : null,
        ),
      ),
      subtitle: Text(
        preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: unread > 0
            ? theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              )
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (last != null)
                Text(
                  formatWhen(last.sentAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (unread > 0) ...[
                const SizedBox(height: 4),
                _CountBadge(count: unread),
              ],
            ],
          ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Delete request',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;

  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final palette = VayuPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: palette.accent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.surface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
