import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/features/connection/providers/file_transfer_provider.dart';
import 'package:silosend/models/transfer_models.dart';
import 'package:silosend/models/transport_models.dart';

class FileTransferProgressView extends ConsumerWidget {
  const FileTransferProgressView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transferState = ref.watch(fileTransferProvider);
    final transferNotifier = ref.read(fileTransferProvider.notifier);

    if (transferState.items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Transfer Queue',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (int i = 0; i < transferState.items.length; i++) ...[
              if (i != 0) const SizedBox(height: 12),
              _TransferItemCard(
                item: transferState.items[i],
                onPause: transferState.items[i].canPause
                    ? () => transferNotifier.pauseTransfer(
                        transferState.items[i].id,
                      )
                    : null,
                onResume: transferState.items[i].canResume
                    ? () => transferNotifier.resumeTransfer(
                        transferState.items[i].id,
                      )
                    : null,
                onCancel: transferState.items[i].isTerminal
                    ? null
                    : () => transferNotifier.cancelTransfer(
                        transferState.items[i].id,
                      ),
                onRetry: transferState.items[i].canRetry
                    ? () => transferNotifier.retryTransfer(
                        transferState.items[i].id,
                      )
                    : null,
              ),
            ],
            if (transferState.errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                transferState.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TransferItemCard extends StatelessWidget {
  final TransferItem item;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  const _TransferItemCard({
    required this.item,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconData = item.direction == TransferDirection.outgoing
        ? Icons.upload
        : Icons.download;
    final directionLabel = item.direction == TransferDirection.outgoing
        ? 'Sending'
        : 'Receiving';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  iconData,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$directionLabel - ${item.peerName}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _transportLabel(item),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _statusLabel(item.status),
                style: theme.textTheme.labelMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: item.progress,
            minHeight: 8,
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(item.progress * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                '${_formatBytes(item.transferredBytes)} / ${_formatBytes(item.totalBytes)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          if (item.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              item.errorMessage!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (item.canPause)
                OutlinedButton.icon(
                  onPressed: onPause,
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
              if (item.canResume)
                OutlinedButton.icon(
                  onPressed: onResume,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
              if (!item.isTerminal)
                OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel'),
                ),
              if (item.canRetry)
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusLabel(TransferStatus status) {
    return switch (status) {
      TransferStatus.queued => 'Queued',
      TransferStatus.preparing => 'Preparing',
      TransferStatus.transferring => 'Sending',
      TransferStatus.receiving => 'Receiving',
      TransferStatus.paused => 'Paused',
      TransferStatus.verifying => 'Verifying',
      TransferStatus.completed => 'Completed',
      TransferStatus.failed => 'Failed',
      TransferStatus.canceled => 'Canceled',
    };
  }

  String _transportLabel(TransferItem item) {
    final mode = switch (item.transportMode) {
      TransferTransportMode.chunkedText => 'Auto transport: lightweight path',
      TransferTransportMode.nativeFile => 'Auto transport: native Wi-Fi file',
    };
    return '$mode • ${item.transportReason}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
