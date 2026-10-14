import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/transfer/transfer_history_page.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Home "Transfers" section: a compact row per active or recent transfer.
///
/// Rows show real engine progress and open [TransferDetailPage] on tap; the
/// full send/receive/completion experience lives there.
class TransferProgressCard extends StatelessWidget {
  final AppContainer container;
  final Stream<List<TransferTask>>? transfersStream;
  final List<TransferTask>? initialTransfers;

  const TransferProgressCard({
    super.key,
    required this.container,
    this.transfersStream,
    this.initialTransfers,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<List<TransferTask>>(
      stream: transfersStream ?? container.activeTransfersStream,
      initialData:
          initialTransfers ?? container.fileSharingCoordinator.allTransfers,
      builder: (context, snapshot) {
        final transfers = snapshot.data ?? [];
        final hasHistory = container.transferHistory.isNotEmpty;
        if (transfers.isEmpty && !hasHistory) {
          return const SizedBox.shrink();
        }

        final activeCount = transfers
            .where(
              (t) =>
                  t.status == TransferStatus.transferring ||
                  t.status == TransferStatus.paused ||
                  t.status == TransferStatus.verifying,
            )
            .length;

        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(
                title: 'Transfers',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (activeCount > 0)
                      StatusPill(
                        label: '$activeCount active',
                        foreground: theme.colorScheme.onPrimaryContainer,
                        background: theme.colorScheme.primaryContainer,
                      ),
                    if (hasHistory)
                      TextButton(
                        onPressed: () =>
                            TransferHistoryPage.open(context, container),
                        child: const Text('History'),
                      ),
                  ],
                ),
              ),
              if (transfers.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                  child: Text(
                    'Nothing in progress.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < transfers.length; i++) ...[
                        if (i > 0) const Divider(indent: 72, endIndent: 16),
                        _TransferRow(container: container, task: transfers[i]),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TransferRow extends StatelessWidget {
  final AppContainer container;
  final TransferTask task;

  const _TransferRow({required this.container, required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final inbound = task is InboundTransferTask;
    final status = task.status;

    return InkWell(
      onTap: () => TransferDetailPage.open(context, container, task: task),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: status == TransferStatus.completed
                    ? palette.successContainer
                    : theme.colorScheme.primaryContainer,
              ),
              child: Icon(
                status == TransferStatus.completed
                    ? Icons.check_rounded
                    : inbound
                    ? Icons.south_rounded
                    : Icons.north_east_rounded,
                color: status == TransferStatus.completed
                    ? palette.success
                    : theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: StreamBuilder<TransferProgress>(
                stream: task.progressStream,
                initialData: latestProgressOf(task),
                builder: (context, snapshot) {
                  final progress = snapshot.data;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.metadata.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 3),
                      _subtitle(context, progress),
                      if (status == TransferStatus.transferring ||
                          status == TransferStatus.paused) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: progress?.fraction,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ],
                      if (status == TransferStatus.completed)
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => _shareAgain(context),
                              child: const Text('Share again'),
                            ),
                            TextButton(
                              onPressed: () => container.fileSharingCoordinator
                                  .dismissCompletedTask(task.transferId),
                              child: const Text('Done'),
                            ),
                          ],
                        ),
                    ],
                  );
                },
              ),
            ),
            if (status == TransferStatus.transferring ||
                status == TransferStatus.idle)
              IconButton(
                tooltip: 'Cancel transfer',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => task.cancel('Cancelled by user'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _subtitle(BuildContext context, TransferProgress? progress) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final style = theme.textTheme.bodySmall;
    switch (task.status) {
      case TransferStatus.transferring:
        final t = task;
        if (t is OutboundTransferTask && t.awaitingAcceptance) {
          return Text('Waiting for the other device to accept…', style: style);
        }
        if (progress == null) return Text('Starting…', style: style);
        final parts = [
          '${progress.percentage}%',
          formatSpeed(progress.speedBytesPerSecond),
          ?formatRemaining(progress.etaSeconds),
        ];
        return Text(parts.join(' · '), style: style);
      case TransferStatus.paused:
        return Text('Paused', style: style);
      case TransferStatus.verifying:
        return Text('Verifying…', style: style);
      case TransferStatus.completed:
        return Row(
          children: [
            Icon(Icons.verified_rounded, size: 14, color: palette.success),
            const SizedBox(width: 4),
            Text(
              'Verified successfully',
              style: style?.copyWith(color: palette.success),
            ),
            Text(' · ${formatBytes(task.metadata.totalBytes)}', style: style),
          ],
        );
      case TransferStatus.failed:
        return Text('Failed', style: style?.copyWith(color: palette.danger));
      case TransferStatus.cancelled:
        return Text('Cancelled', style: style);
      case TransferStatus.idle:
      case TransferStatus.queued:
      case TransferStatus.connecting:
        return Text(
          task is InboundTransferTask
              ? 'Starting…'
              : 'Waiting for the other device…',
          style: style,
        );
    }
  }

  Future<void> _shareAgain(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final next = await container.fileSharingCoordinator.shareAgain(
        task.remoteDeviceId,
      );
      if (next != null && context.mounted) {
        await TransferDetailPage.open(
          context,
          container,
          transferId: next.transferId,
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not share again: $e')),
      );
    }
  }
}
