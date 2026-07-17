import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/features/connection/presentation/file_picker_view.dart';
import 'package:silosend/features/connection/presentation/file_transfer_progress_view.dart';
import 'package:silosend/features/connection/providers/connection_provider.dart'
    as connection;

class TransferScreen extends ConsumerWidget {
  const TransferScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connection.connectionProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              title: const Text('Transfer'),
              actions: [
                IconButton(
                  tooltip: 'Refresh connection',
                  onPressed: () => ref
                      .read(connection.connectionProvider.notifier)
                      .reconnect(),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate.fixed([
                  _ConnectionBanner(connectionState: connectionState),
                  const SizedBox(height: 16),
                  const FilePickerView(),
                  const SizedBox(height: 16),
                  const FileTransferProgressView(),
                  const SizedBox(height: 20),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Phase 4 focus',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'This screen now drives the real queue, chunking, sending, receiving, merge, and verification flow over the active P2P connection.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
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

class _ConnectionBanner extends StatelessWidget {
  final connection.ConnectionState connectionState;

  const _ConnectionBanner({required this.connectionState});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected =
        connectionState.status == connection.ConnectionStatus.connected;

    return Card(
      color: isConnected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              isConnected ? Icons.link : Icons.link_off,
              color: isConnected
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
              size: 30,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isConnected
                        ? 'Connected to ${connectionState.device?.name ?? 'peer'}'
                        : 'No active transfer connection',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isConnected
                        ? 'Files can now be queued and transferred.'
                        : 'Go back to Discovery or Connection to establish a peer link first.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
