import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/constants.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final devices = <_NearbyDevice>[
      const _NearbyDevice(
        name: 'Ava’s Phone',
        distanceLabel: '1.2 km',
        status: 'Available',
      ),
      const _NearbyDevice(
        name: 'Mi Note',
        distanceLabel: '780 m',
        status: 'Available',
      ),
      const _NearbyDevice(
        name: 'Sam’s Tablet',
        distanceLabel: '2.4 km',
        status: 'Connecting',
      ),
    ];

    final recentTransfers = <_RecentTransfer>[
      const _RecentTransfer(
        fileName: 'Design_Sprint.pdf',
        peerName: 'Mi Note',
        direction: _TransferDirection.received,
        state: 'Completed',
        timestampLabel: 'Yesterday',
      ),
      const _RecentTransfer(
        fileName: 'Vacation_2025.zip',
        peerName: 'Ava’s Phone',
        direction: _TransferDirection.sent,
        state: 'In progress',
        timestampLabel: 'Today',
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 110,
              flexibleSpace: FlexibleSpaceBar(
                title: Text('SiloSend', style: theme.textTheme.titleLarge),
              ),
              actions: [
                IconButton(
                  tooltip: 'Go to History',
                  onPressed: () =>
                      GoRouter.of(context).go(AppConstants.routeHistory),
                  icon: const Icon(Icons.history),
                ),
                IconButton(
                  tooltip: 'About',
                  onPressed: () =>
                      GoRouter.of(context).go(AppConstants.routeAbout),
                  icon: const Icon(Icons.info_outline),
                ),
                const SizedBox(width: 8),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Nearby devices', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    _DevicesCard(devices: devices),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () {
                              GoRouter.of(
                                context,
                              ).go(AppConstants.routeTransfer);
                            },
                            icon: const Icon(Icons.send),
                            label: const Text('Send Files'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: () {
                              GoRouter.of(
                                context,
                              ).go(AppConstants.routeTransfer);
                            },
                            icon: const Icon(Icons.download),
                            label: const Text('Receive'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    FilledButton.tonalIcon(
                      onPressed: () =>
                          GoRouter.of(context).go(AppConstants.routeDiscovery),
                      icon: const Icon(Icons.search),
                      label: const Text('Discover devices'),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Recent transfers',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    _RecentTransfersList(items: recentTransfers),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

class _NearbyDevice {
  final String name;
  final String distanceLabel;
  final String status;

  const _NearbyDevice({
    required this.name,
    required this.distanceLabel,
    required this.status,
  });
}

enum _TransferDirection { sent, received }

class _RecentTransfer {
  final String fileName;
  final String peerName;
  final _TransferDirection direction;
  final String state;
  final String timestampLabel;

  const _RecentTransfer({
    required this.fileName,
    required this.peerName,
    required this.direction,
    required this.state,
    required this.timestampLabel,
  });
}

class _DevicesCard extends StatelessWidget {
  final List<_NearbyDevice> devices;

  const _DevicesCard({required this.devices});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          for (int i = 0; i < devices.length; i++) ...[
            if (i != 0) const Divider(height: 16),
            Material(
              color: Colors.transparent,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: const Icon(Icons.phone_android),
                ),
                title: Text(devices[i].name),
                subtitle: Text(
                  '${devices[i].distanceLabel} • ${devices[i].status}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  // Phase 1: UI only.
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecentTransfersList extends StatelessWidget {
  final List<_RecentTransfer> items;

  const _RecentTransfersList({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = items[index];
        final iconData = item.direction == _TransferDirection.sent
            ? Icons.upload
            : Icons.download;
        final directionLabel = item.direction == _TransferDirection.sent
            ? 'Sent'
            : 'Received';

        return Card(
          clipBehavior: Clip.antiAlias,
          color: theme.colorScheme.surfaceContainerHigh,
          child: InkWell(
            onTap: () {
              // Phase 1 UI only.
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
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
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$directionLabel • ${item.peerName}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(item.state, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 4),
                      Text(
                        item.timestampLabel,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
