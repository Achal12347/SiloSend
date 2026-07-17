import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:silosend/app/constants.dart';
import 'package:silosend/features/discovery/providers/discovery_provider.dart';

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(discoveryProvider.notifier).startDiscovery();
    });
  }

  @override
  Widget build(BuildContext context) {
    final discoveryState = ref.watch(discoveryProvider);
    final discoveryNotifier = ref.read(discoveryProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Discovery'),
        actions: [
          IconButton(
            tooltip: discoveryState.isHosting
                ? 'Stop hosting'
                : 'Start hosting',
            icon: Icon(
              discoveryState.isHosting ? Icons.wifi_off : Icons.wifi_tethering,
            ),
            onPressed: discoveryState.isHosting
                ? discoveryNotifier.stopHosting
                : discoveryNotifier.startHosting,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: discoveryNotifier.startDiscovery,
          ),
        ],
      ),
      body: _buildBody(context, discoveryState, discoveryNotifier),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DiscoveryState discoveryState,
    DiscoveryNotifier discoveryNotifier,
  ) {
    switch (discoveryState.status) {
      case DiscoveryStatus.searching:
        return const Center(child: CircularProgressIndicator());

      case DiscoveryStatus.initial:
      case DiscoveryStatus.done:
      case DiscoveryStatus.hosting:
        if (discoveryState.devices.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (discoveryState.isHosting) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.wifi_tethering),
                            const SizedBox(width: 12),
                            Text(
                              'Hosting this device',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('SSID: ${discoveryState.hostSsid ?? "Pending"}'),
                        Text('Key: ${discoveryState.hostKey ?? "Pending"}'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.radar_outlined, size: 44),
                      const SizedBox(height: 12),
                      Text(
                        'No nearby devices found yet.',
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Try scanning again to refresh the list.',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: discoveryNotifier.startDiscovery,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Scan for Devices'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }

        return RefreshIndicator(
          onRefresh: discoveryNotifier.startDiscovery,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            itemCount: discoveryState.devices.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final device = discoveryState.devices[index];
              final initial = device.name.isNotEmpty
                  ? device.name.substring(0, 1).toUpperCase()
                  : '?';

              return Card(
                child: ListTile(
                  leading: CircleAvatar(child: Text(initial)),
                  title: Text(
                    device.name.isNotEmpty ? device.name : 'Unknown Device',
                  ),
                  subtitle: Text('${device.distanceLabel} - ${device.id}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => GoRouter.of(
                    context,
                  ).go(AppConstants.routeConnection, extra: device),
                ),
              );
            },
          ),
        );

      case DiscoveryStatus.error:
        return Center(
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                    size: 44,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    discoveryState.errorMessage ?? 'An unknown error occurred.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: discoveryNotifier.startDiscovery,
                    child: const Text('Try Again'),
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }
}
