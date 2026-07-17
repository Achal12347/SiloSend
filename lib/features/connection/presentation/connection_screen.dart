import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/constants.dart';
import '../../../providers/connection_provider.dart';

class ConnectionScreen extends ConsumerWidget {
  const ConnectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final connectionState = ref.watch(connectionProvider);

    final deviceId =
        connectionState.deviceId ??
        (GoRouterState.of(context).extra is String
            ? GoRouterState.of(context).extra as String
            : null);

    // If we arrived with an extra deviceId but provider doesn't know it yet,
    // set it once. (Mock-only.)
    if (deviceId != null && connectionState.deviceId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(connectionProvider.notifier).setDevice(deviceId);
      });
    }

    final isBusy =
        connectionState.status == ConnectionStatus.validating ||
        connectionState.status == ConnectionStatus.connecting ||
        connectionState.status == ConnectionStatus.disconnecting;

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverAppBar(pinned: true, title: Text('Connection')),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate.fixed([
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Target device',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            deviceId ?? 'Not selected',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Status: ${connectionState.status.name}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color:
                                  connectionState.status ==
                                      ConnectionStatus.error
                                  ? Colors.redAccent
                                  : null,
                            ),
                          ),
                          if (connectionState.errorMessage != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              connectionState.errorMessage!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.redAccent,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Connection controls (Phase 3 UI-only mock)',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: isBusy || deviceId == null
                                    ? null
                                    : () => ref
                                          .read(connectionProvider.notifier)
                                          .connect(),
                                icon: const Icon(Icons.link),
                                label: const Text('Connect'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: isBusy || deviceId == null
                                    ? null
                                    : () => ref
                                          .read(connectionProvider.notifier)
                                          .disconnect(),
                                icon: const Icon(Icons.link_off),
                                label: const Text('Disconnect'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: isBusy || deviceId == null
                                    ? null
                                    : () => ref
                                          .read(connectionProvider.notifier)
                                          .reconnect(),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Reconnect'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Timeout simulation:',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          FilledButton.icon(
                            onPressed: isBusy || deviceId == null
                                ? null
                                : () async {
                                    // Mock “timeout connect”: go to connectWithTimeout path
                                    // by reusing provider’s connect after setting device.
                                    // We keep it simple: update UI state to connected/error.
                                    // (Provider uses a 1s timeout internally.)
                                    await ref
                                        .read(connectionProvider.notifier)
                                        .connect();
                                  },
                            icon: const Icon(Icons.timer_outlined),
                            label: const Text('Connect with timeout'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Phase 3 rules: no BLE/WiFi implemented, no file transfer, no messaging.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                child: Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () =>
                          GoRouter.of(context).go(AppConstants.routeDiscovery),
                      icon: const Icon(Icons.search),
                      label: const Text('Back to Discovery'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension _NameExt on ConnectionStatus {
  String get name => toString().split('.').last;
}
