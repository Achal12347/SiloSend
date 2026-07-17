import 'package:flutter/material.dart';

class TransferScreen extends StatelessWidget {
  const TransferScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final queue = <_TransferQueueItem>[
      const _TransferQueueItem(
        fileName: 'Design_Sprint.pdf',
        peerName: 'Mi Note',
        direction: _TransferDirection.received,
        progressLabel: '32%',
        speedLabel: '1.4 MB/s',
        etaLabel: '~3m',
        stateLabel: 'Transferring',
      ),
      const _TransferQueueItem(
        fileName: 'Vacation_2025.zip',
        peerName: 'Ava’s Phone',
        direction: _TransferDirection.sent,
        progressLabel: '—',
        speedLabel: '—',
        etaLabel: '—',
        stateLabel: 'Queued',
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverAppBar(pinned: true, title: Text('Transfer')),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate.fixed([
                  Text('Queue (mock)', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  for (int i = 0; i < queue.length; i++) ...[
                    if (i != 0) const SizedBox(height: 12),
                    _TransferCard(item: queue[i]),
                  ],
                  const SizedBox(height: 18),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Transfer controls (UI only)',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: null,
                                icon: const Icon(Icons.pause_circle_outline),
                                label: const Text('Pause'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: null,
                                icon: const Icon(Icons.play_circle_outline),
                                label: const Text('Resume'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: null,
                                icon: const Icon(Icons.cancel_outlined),
                                label: const Text('Cancel'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: null,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry failed'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Phase 1: Transfer UI uses mock queue items only. No file transfer engine yet.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _TransferDirection { sent, received }

class _TransferQueueItem {
  final String fileName;
  final String peerName;
  final _TransferDirection direction;
  final String progressLabel;
  final String speedLabel;
  final String etaLabel;
  final String stateLabel;

  const _TransferQueueItem({
    required this.fileName,
    required this.peerName,
    required this.direction,
    required this.progressLabel,
    required this.speedLabel,
    required this.etaLabel,
    required this.stateLabel,
  });
}

class _TransferCard extends StatelessWidget {
  final _TransferQueueItem item;

  const _TransferCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final iconData = item.direction == _TransferDirection.sent
        ? Icons.upload
        : Icons.download;
    final directionLabel = item.direction == _TransferDirection.sent
        ? 'Sent'
        : 'Received';

    final progress = switch (item.progressLabel) {
      final String p when p.endsWith('%') =>
        double.tryParse(p.replaceAll('%', '')) != null
            ? (double.parse(p.replaceAll('%', '')) / 100).clamp(0.0, 1.0)
            : null,
      _ => null,
    };

    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                        '$directionLabel • ${item.peerName}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (progress != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(item.stateLabel, style: theme.textTheme.bodyMedium),
                Text(
                  item.progressLabel == '—' ? '' : item.progressLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Speed: ${item.speedLabel}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: Text(
                    'ETA: ${item.etaLabel}',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.cancel),
                    label: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
