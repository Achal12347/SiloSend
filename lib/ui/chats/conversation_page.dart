import 'package:flutter/material.dart';

import 'package:vayu/core/chat/chat_service.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/domain/chat/chat_payloads.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/transfer/transfer_batch.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/transfer/selected_items_page.dart' show fileIconFor;
import 'package:vayu/ui/transfer/transfer_detail_page.dart'
    show latestProgressOf;
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// One conversation. Opening it accepts a message request and marks the
/// messages read (the sender then sees "Seen").
class ConversationPage extends StatefulWidget {
  final AppContainer container;
  final String peerDeviceId;
  final String peerName;

  const ConversationPage({
    super.key,
    required this.container,
    required this.peerDeviceId,
    required this.peerName,
  });

  static Future<void> open(
    BuildContext context,
    AppContainer container, {
    required String peerDeviceId,
    required String peerName,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ConversationPage(
        container: container,
        peerDeviceId: peerDeviceId,
        peerName: peerName,
      ),
    ),
  );

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  bool _sending = false;

  ChatService get _chat => widget.container.chatService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chat.open(widget.peerDeviceId);
    // Files offered while this chat is on screen are taken at once.
    _chat.setVisible(widget.peerDeviceId, true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // In the background the chat is not on screen: files wait on hold.
    _chat.setVisible(widget.peerDeviceId, state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chat.setVisible(widget.peerDeviceId, false);
    _input.dispose();
    super.dispose();
  }

  DiscoveredPeer? get _nearbyPeer {
    final id = widget.peerDeviceId.toLowerCase();
    return widget.container.discoveredPeers
        .where((p) => p.deviceId.toLowerCase() == id)
        .firstOrNull;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    try {
      await _chat.send(
        deviceId: widget.peerDeviceId,
        peerName: widget.peerName,
        text: text,
      );
    } catch (e) {
      if (mounted) {
        showVayuNotice(
          context,
          e is ChatUnavailableException
              ? "${widget.peerName} isn't nearby. The message is sent when you meet again."
              : 'The message could not be sent.',
          tone: VayuNoticeTone.problem,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    // New messages arriving while open are read at once.
    _chat.open(widget.peerDeviceId);
  }

  Future<void> _retry(ChatMessage message) async {
    try {
      await _chat.retry(widget.peerDeviceId, message.id);
    } catch (_) {
      if (mounted) {
        showVayuNotice(
          context,
          "Still can't reach ${widget.peerName}.",
          tone: VayuNoticeTone.problem,
        );
      }
    }
  }

  /// Files go into the chat: the other phone accepts them there.
  Future<void> _attach() async {
    final List<SelectedDocument> docs;
    try {
      docs = await widget.container.filePickerService.pickMultipleDocuments();
    } catch (_) {
      if (mounted) {
        showVayuNotice(
          context,
          "Couldn't open your files. Please try again.",
          tone: VayuNoticeTone.problem,
        );
      }
      return;
    }
    if (docs.isEmpty || !mounted) return;
    if (docs.length > ChatFileOfferPayload.maxFiles) {
      showVayuNotice(
        context,
        'Send at most ${ChatFileOfferPayload.maxFiles} files at a time.',
        tone: VayuNoticeTone.problem,
      );
      return;
    }
    try {
      await _chat.sendFiles(
        deviceId: widget.peerDeviceId,
        peerName: widget.peerName,
        documents: docs,
      );
    } catch (e) {
      if (mounted) {
        showVayuNotice(
          context,
          e is ChatUnavailableException
              ? e.message.contains('older Vayu')
                    ? '${widget.peerName} needs to update Vayu to get files in chats.'
                    : "${widget.peerName} isn't nearby. Tap the message to try again."
              : 'The files could not be offered.',
          tone: VayuNoticeTone.problem,
        );
      }
    }
  }

  Future<void> _accept(ChatMessage m) async {
    try {
      await _chat.acceptFiles(widget.peerDeviceId, m.id);
    } catch (_) {
      if (mounted) {
        showVayuNotice(
          context,
          "Can't reach ${widget.peerName} now. Try again when you're close.",
          tone: VayuNoticeTone.problem,
        );
      }
    }
  }

  Future<void> _openFile(ChatFile f) async {
    final path = f.savedPath;
    if (path == null) return;
    final ok = await widget.container.platformService.openFile(
      path,
      mimeType: f.mimeType,
    );
    if (!ok && mounted) {
      showVayuNotice(context, 'No app on this phone opens that file.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<Conversation>>(
      stream: _chat.changes,
      builder: (context, _) {
        final conversation = _chat.conversationWith(widget.peerDeviceId);
        final messages = conversation?.messages ?? const <ChatMessage>[];
        // Messages that arrive while the screen is open are read.
        if (conversation != null && conversation.unread > 0) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _chat.open(widget.peerDeviceId),
          );
        }
        final nearby = _nearbyPeer != null;
        final lastMine = messages.lastWhere(
          (m) => m.fromMe,
          orElse: () => ChatMessage(
            id: '',
            fromMe: true,
            text: '',
            sentAt: DateTime(0),
            state: MessageState.sent,
          ),
        );
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                DeviceAvatar(
                  name: widget.peerName,
                  seed: widget.peerDeviceId,
                  size: 36,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation?.peerName ?? widget.peerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        nearby ? 'Nearby' : 'Not nearby',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              'Say hello. Messages go straight to '
                              '${widget.peerName}, encrypted, without internet.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                          itemCount: messages.length,
                          itemBuilder: (context, i) {
                            final m = messages[messages.length - 1 - i];
                            if (m.isFile) {
                              return _FileBubble(
                                container: widget.container,
                                message: m,
                                peerName: widget.peerName,
                                onAccept: () => _accept(m),
                                onDecline: () => _chat.declineFiles(
                                  widget.peerDeviceId,
                                  m.id,
                                ),
                                onRetrySend: () => _retry(m),
                                onOpen: _openFile,
                              );
                            }
                            return _Bubble(
                              message: m,
                              showState: m.fromMe && m.id == lastMine.id,
                              onRetry: m.state == MessageState.failed
                                  ? () => _retry(m)
                                  : null,
                            );
                          },
                        ),
                ),
                _Composer(
                  controller: _input,
                  sending: _sending,
                  onSend: _send,
                  onAttach: _attach,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool showState;
  final VoidCallback? onRetry;

  const _Bubble({required this.message, required this.showState, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final mine = message.fromMe;
    final failed = message.state == MessageState.failed;
    final bg = mine
        ? (failed ? palette.dangerContainer : theme.colorScheme.primary)
        : theme.colorScheme.surfaceContainerHigh;
    final fg = mine
        ? (failed ? palette.danger : theme.colorScheme.onPrimary)
        : theme.colorScheme.onSurface;
    final status = switch (message.state) {
      MessageState.sending => 'Sending…',
      MessageState.sent => 'Sent',
      MessageState.delivered => 'Delivered',
      MessageState.read => 'Seen',
      MessageState.failed => 'Not sent · tap to try again',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onRetry,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.78,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(20),
                    topRight: const Radius.circular(20),
                    bottomLeft: Radius.circular(mine ? 20 : 6),
                    bottomRight: Radius.circular(mine ? 6 : 20),
                  ),
                ),
                child: Text(
                  message.text,
                  style: theme.textTheme.bodyLarge?.copyWith(color: fg),
                ),
              ),
            ),
          ),
          if (showState || failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 3, 6, 2),
              child: Text(
                status,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: failed
                      ? palette.danger
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Files in the chat, drawn like a messenger attachment: the files, then
/// what is happening with them; an incoming offer on hold has Download and
/// Decline in the bubble itself (no popup).
class _FileBubble extends StatelessWidget {
  final AppContainer container;
  final ChatMessage message;
  final String peerName;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onRetrySend;
  final ValueChanged<ChatFile> onOpen;

  const _FileBubble({
    required this.container,
    required this.message,
    required this.peerName,
    required this.onAccept,
    required this.onDecline,
    required this.onRetrySend,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final mine = message.fromMe;
    final bg = mine
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHigh;
    final fg = mine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final sub = fg.withValues(alpha: 0.75);
    final files = message.files;
    final count = files.length;
    final summary =
        '$count ${count == 1 ? 'file' : 'files'} · ${formatBytes(message.totalBytes)}';
    final notSent = mine && message.state == MessageState.failed;
    final onHold = !mine && message.fileState == ChatFileState.offered;
    final canRetryReceive = !mine && message.fileState == ChatFileState.failed;
    final done = message.fileState == ChatFileState.done;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.8,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(mine ? 20 : 6),
                bottomRight: Radius.circular(mine ? 6 : 20),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final f in files.take(3))
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: !mine && done && f.savedPath != null
                        ? () => onOpen(f)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: fg.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              fileIconFor(f.name, f.mimeType),
                              color: fg,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  f.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: fg,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  formatBytes(f.sizeBytes),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: sub,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!mine && done && f.savedPath != null)
                            Icon(
                              Icons.open_in_new_rounded,
                              size: 18,
                              color: sub,
                            ),
                        ],
                      ),
                    ),
                  ),
                if (count > 3)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '+ ${count - 3} more',
                      style: theme.textTheme.labelMedium?.copyWith(color: sub),
                    ),
                  ),
                const SizedBox(height: 6),
                if (message.fileState == ChatFileState.transferring &&
                    message.batchId != null)
                  _BatchProgress(
                    container: container,
                    batchId: message.batchId!,
                    color: fg,
                    track: fg.withValues(alpha: 0.2),
                  )
                else
                  Text(
                    _status(summary, notSent),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: notSent ? palette.dangerContainer : sub,
                    ),
                  ),
                if (onHold || canRetryReceive) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (onHold)
                        Expanded(
                          child: OutlinedButton(
                            onPressed: onDecline,
                            child: const Text('Decline'),
                          ),
                        ),
                      if (onHold) const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: onAccept,
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text(onHold ? 'Download' : 'Try again'),
                        ),
                      ),
                    ],
                  ),
                ],
                if (notSent)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: onRetrySend,
                      style: TextButton.styleFrom(foregroundColor: fg),
                      child: const Text('Try again'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _status(String summary, bool notSent) {
    if (notSent) return '$summary · not sent';
    if (message.fromMe) {
      return switch (message.fileState) {
        ChatFileState.offered =>
          message.state == MessageState.sending
              ? '$summary · sending…'
              : '$summary · waiting for $peerName to download',
        ChatFileState.accepted ||
        ChatFileState.transferring => '$summary · starting…',
        ChatFileState.done => '$summary · delivered',
        ChatFileState.declined => '$summary · $peerName declined',
        ChatFileState.failed => "$summary · didn't arrive",
        ChatFileState.unavailable || null => '$summary · no longer available',
      };
    }
    return switch (message.fileState) {
      ChatFileState.offered => summary,
      ChatFileState.accepted ||
      ChatFileState.transferring => '$summary · starting…',
      ChatFileState.done => '$summary · tap a file to open it',
      ChatFileState.declined => '$summary · declined',
      ChatFileState.failed => "$summary · didn't arrive",
      ChatFileState.unavailable ||
      null => '$summary · no longer available ($peerName restarted Vayu)',
    };
  }
}

/// Live progress of the transfer carrying a chat message's files.
class _BatchProgress extends StatelessWidget {
  final AppContainer container;
  final String batchId;
  final Color color;
  final Color track;

  const _BatchProgress({
    required this.container,
    required this.batchId,
    required this.color,
    required this.track,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sharing = container.fileSharingCoordinator;
    return StreamBuilder<void>(
      stream: sharing.activeTransfersStream,
      builder: (context, _) {
        final TransferBatch? batch = sharing.getBatch(batchId);
        final total = batch?.totalBytes ?? 0;
        final done = batch?.bytesDone(latestProgressOf) ?? 0;
        final fraction = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 5,
                color: color,
                backgroundColor: track,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              total > 0
                  ? '${formatBytes(done)} of ${formatBytes(total)}'
                  : 'Starting…',
              style: theme.textTheme.labelSmall?.copyWith(
                color: color.withValues(alpha: 0.8),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Send files',
            onPressed: onAttach,
            icon: const Icon(Icons.attach_file_rounded),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              maxLength: ChatMessagePayload.maxLength,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Message',
                counterText: '',
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHigh,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            tooltip: 'Send',
            onPressed: sending ? null : onSend,
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}
