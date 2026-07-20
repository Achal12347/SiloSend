import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/connection_provider.dart' as connection;
import 'file_picker_view.dart';
import 'file_transfer_progress_view.dart';

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
                            'Automatic transport selection',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'The transfer layer now chooses the transport automatically. Text and small files stay on the lightweight path, large files switch to the native Wi-Fi path, and the queue keeps the reason with each item.',
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

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: Card(
        color: isConnected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHigh,
        child: Semantics(
          container: true,
          label: isConnected
              ? 'Connected to ${connectionState.device?.name ?? 'peer'}'
              : 'No active transfer connection',
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                AnimatedScale(
                  duration: const Duration(milliseconds: 260),
                  scale: isConnected ? 1.0 : 0.96,
                  child: Icon(
                    isConnected ? Icons.link : Icons.link_off,
                    color: isConnected
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                    size: 30,
                  ),
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
        ),
      ),
    );
  }
}
