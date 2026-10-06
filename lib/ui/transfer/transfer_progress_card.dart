import 'package:flutter/material.dart';
import 'package:silosend_datasharing_app/core/contracts/transfer_contract.dart';
import 'package:silosend_datasharing_app/core/state/app_container.dart';
import 'package:silosend_datasharing_app/core/transfer/transfer_task_impl.dart';
import 'package:silosend_datasharing_app/domain/models/transfer_models.dart';
import 'package:silosend_datasharing_app/domain/transfer/payload_destination.dart';

/// Renders active and recently completed file transfer tasks with live
/// speed, ETA, progress bars, pause/resume, and cancellation controls.
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
        if (transfers.isEmpty) {
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

        return Card(
          elevation: 0,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.swap_vert_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'File Transfers',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    if (activeCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$activeCount Active',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                  ],
                ),
                const Divider(height: 20),
                Column(
                  children: transfers
                      .map((task) => _buildTransferItem(context, theme, task))
                      .toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTransferItem(
    BuildContext context,
    ThemeData theme,
    TransferTask task,
  ) {
    final isOutbound = task is! InboundTransferTask;
    final meta = task.metadata;

    return Container(
      margin: const EdgeInsets.only(bottom: 12.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isOutbound
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 16,
                color: isOutbound
                    ? Colors.blue.shade700
                    : Colors.green.shade700,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  meta.fileName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _buildStatusBadge(theme, task.status),
            ],
          ),
          const SizedBox(height: 8),

          // Real-time progress updates
          StreamBuilder<TransferProgress>(
            stream: task.progressStream,
            builder: (context, progressSnapshot) {
              final progress = progressSnapshot.data;
              if (progress == null) {
                return Text(
                  'Waiting for transfer status...',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: (task.status == TransferStatus.completed)
                        ? 1.0
                        : progress.fraction,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                    color: _progressBarColor(task.status),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_formatBytes(progress.bytesTransferred)} / ${_formatBytes(meta.totalBytes)} (${progress.percentage}%)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (task.status == TransferStatus.transferring)
                        Text(
                          '${_formatSpeed(progress.speedBytesPerSecond)} • ${_formatEta(progress.etaSeconds ?? 0)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),

          // Action controls
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (task.status == TransferStatus.transferring) ...[
                OutlinedButton.icon(
                  onPressed: () => task.cancel('Cancelled by user'),
                  icon: const Icon(Icons.close_rounded, size: 14),
                  label: const Text('Cancel'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: Colors.red.shade700,
                    side: BorderSide(color: Colors.red.shade300),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                  ),
                ),
              ] else if (task.status == TransferStatus.completed) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.end,
                  children: [
                    Icon(
                      Icons.verified_rounded,
                      size: 14,
                      color: Colors.green.shade700,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Verified successfully',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade800,
                      ),
                    ),
                    if (task is InboundTransferTask &&
                        task.destination is FilePayloadDestination) ...[
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          final path =
                              (task.destination as FilePayloadDestination)
                                  .targetFilePath;
                          final opened = await container.platformService
                              .openFile(path, mimeType: meta.mimeType);
                          if (!opened && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('File saved to $path')),
                            );
                          }
                        },
                        icon: const Icon(Icons.open_in_new_rounded, size: 14),
                        label: const Text('Open File'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                        ),
                      ),
                    ],
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        try {
                          await container.fileSharingCoordinator.shareAgain(
                            task.remoteDeviceId,
                          );
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Could not share again: $e'),
                              ),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.replay_rounded, size: 14),
                      label: const Text('Share again'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () {
                        container.fileSharingCoordinator.dismissCompletedTask(
                          task.transferId,
                        );
                      },
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                      ),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(ThemeData theme, TransferStatus status) {
    Color bg;
    Color fg;
    String text;

    switch (status) {
      case TransferStatus.transferring:
        bg = Colors.blue.shade100;
        fg = Colors.blue.shade900;
        text = 'Transferring';
        break;
      case TransferStatus.paused:
        bg = Colors.amber.shade100;
        fg = Colors.amber.shade900;
        text = 'Paused';
        break;
      case TransferStatus.completed:
        bg = Colors.green.shade100;
        fg = Colors.green.shade900;
        text = 'Completed';
        break;
      case TransferStatus.failed:
        bg = Colors.red.shade100;
        fg = Colors.red.shade900;
        text = 'Failed';
        break;
      case TransferStatus.cancelled:
        bg = Colors.grey.shade200;
        fg = Colors.grey.shade800;
        text = 'Cancelled';
        break;
      default:
        bg = theme.colorScheme.surfaceContainerHighest;
        fg = theme.colorScheme.onSurfaceVariant;
        text = status.name;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fg),
      ),
    );
  }

  Color _progressBarColor(TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return Colors.green.shade600;
      case TransferStatus.paused:
        return Colors.amber.shade700;
      case TransferStatus.failed:
        return Colors.red.shade600;
      case TransferStatus.cancelled:
        return Colors.grey.shade500;
      default:
        return Colors.blue.shade600;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatEta(int seconds) {
    if (seconds <= 0) return 'calculating...';
    if (seconds < 60) return 'ETA: ${seconds}s';
    final minutes = seconds ~/ 60;
    final remainingSecs = seconds % 60;
    return 'ETA: ${minutes}m ${remainingSecs}s';
  }
}
