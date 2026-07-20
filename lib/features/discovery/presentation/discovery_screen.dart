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
            tooltip: 'Refresh discovery',
            icon: const Icon(Icons.refresh),
            onPressed: discoveryNotifier.startDiscovery,
          ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final slide = Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: slide, child: child),
          );
        },
        child: KeyedSubtree(
          key: ValueKey(
            '${discoveryState.status.name}-${discoveryState.isHosting}-${discoveryState.devices.length}',
          ),
          child: _buildBody(context, discoveryState, discoveryNotifier),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    DiscoveryState discoveryState,
    DiscoveryNotifier discoveryNotifier,
  ) {
    switch (discoveryState.status) {
      case DiscoveryStatus.searching:
        return const Center(child: _ScanningState());

      case DiscoveryStatus.initial:
      case DiscoveryStatus.done:
      case DiscoveryStatus.hosting:
        if (discoveryState.devices.isEmpty) {
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (discoveryState.isHosting) ...[
                Semantics(
                  container: true,
                  label:
                      'Hosting this device. Network details are visible below.',
                  child: Card(
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
                child: Semantics(
                  button: true,
                  label:
                      '${device.name.isNotEmpty ? device.name : 'Unknown Device'}, ${device.distanceLabel}',
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

class _ScanningState extends StatefulWidget {
  const _ScanningState();

  @override
  State<_ScanningState> createState() => _ScanningStateState();
}

class _ScanningStateState extends State<_ScanningState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.all(24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final value = 0.92 + (_controller.value * 0.08);
                return Transform.scale(scale: value, child: child);
              },
              child: Icon(
                Icons.radar_outlined,
                size: 48,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Searching for nearby devices',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Discovery is running in the background while we wait for nearby peers to respond.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
