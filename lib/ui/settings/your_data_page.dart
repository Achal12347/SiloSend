import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/security/trusted_devices_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Privacy (Phase 14): what Vayu keeps on this phone, with real counts, and
/// a way to delete each kind. Only Vayu's own app-private data is deleted;
/// files saved to Downloads are the user's and are never touched here.
class YourDataPage extends StatefulWidget {
  final AppContainer container;

  const YourDataPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => YourDataPage(container: container)),
      );

  @override
  State<YourDataPage> createState() => _YourDataPageState();
}

class _YourDataPageState extends State<YourDataPage> {
  AppContainer get _c => widget.container;

  Future<void> _delete({
    required String title,
    required String message,
    required Future<void> Function() action,
    required String done,
  }) async {
    final ok = await showVayuConfirm(
      context,
      title: title,
      message: message,
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    await action();
    if (!mounted) return;
    setState(() {});
    showVayuNotice(context, done, tone: VayuNoticeTone.success);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final chats = _c.chatService.chats.length + _c.chatService.requests.length;
    final messages = _c.chatService.messageCount;
    final history = _c.transferHistory.length;
    final cards = _c.receivedCards?.all.length ?? 0;
    final partials = _c.resumableTransfers;
    final partialCount = partials?.keptPaths.length ?? 0;
    final devices = _c.trustStore.records.length;

    Widget row({
      required IconData icon,
      required String title,
      required String detail,
      required String about,
      VoidCallback? onDelete,
      VoidCallback? onOpen,
    }) => ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title),
      subtitle: Text('$detail\n$about'),
      isThreeLine: true,
      onTap: onOpen,
      trailing: onOpen != null
          ? const Icon(Icons.chevron_right_rounded)
          : IconButton(
              tooltip: 'Delete $title',
              onPressed: onDelete,
              color: palette.danger,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Your data')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Everything below stays on this phone, in Vayu\'s private '
                  'storage. Vayu has no servers, no analytics and no '
                  'advertising IDs: nothing is sent anywhere except to the '
                  'phones you choose.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'Kept on this phone'),
            Card(
              child: Column(
                children: [
                  row(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'Chats',
                    detail:
                        '$chats ${chats == 1 ? 'conversation' : 'conversations'}'
                        ' · $messages ${messages == 1 ? 'message' : 'messages'}',
                    about: 'Encrypted with a key in this phone\'s secure hardware.',
                    onDelete: chats == 0
                        ? null
                        : () => _delete(
                            title: 'Delete all chats?',
                            message:
                                'Every conversation is removed from this '
                                'phone. The other phones keep theirs. Files '
                                'you received stay in Downloads.',
                            action: () async => _c.chatService.deleteAll(),
                            done: 'Chats deleted',
                          ),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  row(
                    icon: Icons.history_rounded,
                    title: 'Transfer history',
                    detail: '$history ${history == 1 ? 'entry' : 'entries'}',
                    about: 'Names, sizes and who sent them; not the files.',
                    onDelete: history == 0
                        ? null
                        : () => _delete(
                            title: 'Clear the history?',
                            message:
                                'The list is emptied. The files themselves '
                                'stay in Downloads.',
                            action: _c.clearHistory,
                            done: 'History cleared',
                          ),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  row(
                    icon: Icons.contact_page_outlined,
                    title: 'Received cards',
                    detail: '$cards ${cards == 1 ? 'card' : 'cards'}',
                    about:
                        'Cards people gave you, until you save or delete '
                        'them.',
                    onDelete: cards == 0
                        ? null
                        : () => _delete(
                            title: 'Delete all received cards?',
                            message:
                                'Cards already saved to your contacts stay '
                                'there.',
                            action: () => _c.receivedCards!.removeAll(),
                            done: 'Received cards deleted',
                          ),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  row(
                    icon: Icons.downloading_rounded,
                    title: 'Unfinished downloads',
                    detail: partialCount == 0
                        ? 'None'
                        : '$partialCount · ${formatBytes(partials!.keptBytes)}',
                    about:
                        'Kept 30 minutes so a dropped transfer can '
                        'continue.',
                    onDelete: partialCount == 0
                        ? null
                        : () => _delete(
                            title: 'Delete unfinished downloads?',
                            message:
                                'Those files start over if they are sent '
                                'again.',
                            action: partials!.discardAll,
                            done: 'Unfinished downloads deleted',
                          ),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  row(
                    icon: Icons.verified_user_outlined,
                    title: 'Trusted devices',
                    detail: '$devices ${devices == 1 ? 'phone' : 'phones'}',
                    about: 'Their identity keys, to notice an impostor.',
                    onOpen: () async {
                      await TrustedDevicesPage.open(context, _c);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'Also on this phone'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '• Your card and name, which you can edit any time.\n'
                  '• This phone\'s identity key, kept in secure hardware; '
                  'it never leaves the phone.\n'
                  '• Files you received, in Downloads/Vayu: they are yours, '
                  'and only you delete them.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
