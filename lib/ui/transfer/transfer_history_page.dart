import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Every finished transfer, newest first, kept across restarts.
///
/// Removing an entry only forgets it here; received files stay where they
/// were saved.
class TransferHistoryPage extends StatefulWidget {
  final AppContainer container;

  const TransferHistoryPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TransferHistoryPage(container: container),
        ),
      );

  @override
  State<TransferHistoryPage> createState() => _TransferHistoryPageState();
}

class _TransferHistoryPageState extends State<TransferHistoryPage> {
  StreamSubscription<List<TransferTask>>? _sub;

  @override
  void initState() {
    super.initState();
    // History grows when transfers finish; the transfers stream fires then.
    _sub = widget.container.activeTransfersStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _remove(TransferHistoryRecord record) async {
    await widget.container.removeFromHistory(record.transferId);
    if (mounted) setState(() {});
  }

  Future<void> _clear() async {
    final confirmed = await showVayuConfirm(
      context,
      title: 'Clear history?',
      message: 'Only the list is cleared. Received files stay on this phone.',
      confirmLabel: 'Clear history',
      destructive: true,
    );
    if (confirmed != true) return;
    await widget.container.clearHistory();
    if (mounted) setState(() {});
  }

  Future<void> _open(TransferHistoryRecord record) =>
      openHistoryRecord(context, widget.container, record);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = widget.container.transferHistory;

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (records.isNotEmpty)
            TextButton(onPressed: _clear, child: const Text('Clear')),
        ],
      ),
      body: SafeArea(
        child: records.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Files you send and receive will be listed here.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: records.length,
                separatorBuilder: (_, _) =>
                    const Divider(indent: 72, endIndent: 16),
                itemBuilder: (context, i) => HistoryRow(
                  record: records[i],
                  onOpen: () => _open(records[i]),
                  onRemove: () => _remove(records[i]),
                ),
              ),
      ),
    );
  }
}

/// Opens a received file from history; says so when it is gone.
/// Shared by the history page and the recent transfers on Home.
Future<void> openHistoryRecord(
  BuildContext context,
  AppContainer container,
  TransferHistoryRecord record,
) async {
  final path = record.savedPath;
  final messenger = ScaffoldMessenger.of(context);
  if (path == null || !File(path).existsSync()) {
    showVayuNotice(
      null,
      messenger: messenger,
      'This file is no longer on your phone.',
    );
    return;
  }
  final opened = await container.platformService.openFile(
    path,
    mimeType: record.isContact ? 'text/x-vcard' : record.mimeType,
  );
  if (!opened) {
    showVayuNotice(null, messenger: messenger, 'Saved in Downloads/Vayu');
  }
}

/// One finished transfer: direction, name, size or failure, and when.
/// Without [onRemove] it has no menu (Home's recent transfers).
class HistoryRow extends StatelessWidget {
  final TransferHistoryRecord record;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  const HistoryRow({
    super.key,
    required this.record,
    required this.onOpen,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final completed = record.outcome == TransferOutcome.completed;
    final canOpen = completed && !record.outbound && record.savedPath != null;

    final Color tint;
    final Color background;
    final IconData icon;
    if (!completed) {
      tint = record.outcome == TransferOutcome.cancelled
          ? theme.colorScheme.onSurfaceVariant
          : palette.danger;
      background = theme.colorScheme.surfaceContainerHighest;
      icon = record.outcome == TransferOutcome.cancelled
          ? Icons.block_rounded
          : Icons.priority_high_rounded;
    } else {
      tint = theme.colorScheme.onPrimaryContainer;
      background = theme.colorScheme.primaryContainer;
      icon = record.outbound ? Icons.north_east_rounded : Icons.south_rounded;
    }

    final direction = record.outbound
        ? 'To ${record.peerName}'
        : 'From ${record.peerName}';
    final status = completed
        ? formatBytes(record.sizeBytes)
        : describeFailureKind(record.failureKind);

    return ListTile(
      onTap: canOpen ? onOpen : null,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(shape: BoxShape.circle, color: background),
        child: Icon(icon, color: tint),
      ),
      title: Text(
        record.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        '$direction · $status\n${formatWhen(record.finishedAt)}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: completed ? null : tint,
        ),
      ),
      isThreeLine: true,
      trailing: onRemove == null
          ? null
          : PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (value) {
                if (value == 'open') onOpen();
                if (value == 'remove') onRemove!();
              },
              itemBuilder: (_) => [
                if (canOpen)
                  const PopupMenuItem(value: 'open', child: Text('Open')),
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove from history'),
                ),
              ],
            ),
    );
  }
}
