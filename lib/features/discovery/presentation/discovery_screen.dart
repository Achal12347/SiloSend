import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/discovery_provider.dart';

import '../../../models/device.dart';

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  @override
  void initState() {
    super.initState();

    // Phase 2: mock-first discovery is triggered on first load.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(discoveryProvider.notifier).startDiscovery();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final statusChips = <_DiscoveryChip>[
      const _DiscoveryChip(label: 'BLE Advertising', enabled: true),
      const _DiscoveryChip(label: 'BLE Scanning', enabled: true),
      const _DiscoveryChip(label: 'WiFi Direct', enabled: true),
    ];

    final discoveryState = ref.watch(discoveryProvider);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverAppBar(pinned: true, title: Text('Discovery')),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate.fixed([
                  Text('Nearby devices', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in statusChips) _MockStatusChip(chip: c),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Auto refresh',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Refreshing with mock discovery (Phase 2).',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  onPressed:
                                      discoveryState.status ==
                                          DiscoveryStatus.loading
                                      ? null
                                      : () async {
                                          await ref
                                              .read(discoveryProvider.notifier)
                                              .refresh();
                                        },
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Manual refresh'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: null,
                                  icon: const Icon(Icons.check_circle_outline),
                                  label: const Text('Trust all (mock)'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Devices', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  if (discoveryState.status == DiscoveryStatus.loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (discoveryState.status == DiscoveryStatus.error)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        discoveryState.errorMessage ??
                            'Discovery failed (mock).',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.redAccent,
                        ),
                      ),
                    )
                  else
                    for (int i = 0; i < discoveryState.devices.length; i++) ...[
                      if (i != 0) const Divider(height: 24),
                      _DeviceTile(device: discoveryState.devices[i]),
                    ],
                  const SizedBox(height: 8),
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                child: Text(
                  'Phase 2: Mock BLE/WiFi discovery wired via Riverpod. No real networking implemented.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveryChip {
  final String label;
  final bool enabled;

  const _DiscoveryChip({required this.label, required this.enabled});
}

class _MockStatusChip extends StatelessWidget {
  final _DiscoveryChip chip;

  const _MockStatusChip({required this.chip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      avatar: Icon(
        chip.enabled ? Icons.toggle_on : Icons.toggle_off,
        size: 18,
        color: chip.enabled
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      label: Text(chip.label, style: theme.textTheme.bodySmall),
      backgroundColor: chip.enabled
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHigh,
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final Device device;

  const _DeviceTile({required this.device});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: const Icon(Icons.devices),
      ),
      title: Text(device.name),
      subtitle: Text(device.distanceLabel),
      trailing: const Icon(Icons.chevron_right),
      onTap: null,
    );
  }
}
