import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:silosend/app/constants.dart';
import 'package:silosend/core/theme/app_spacing.dart';
import 'package:silosend/features/home/presentation/widgets/app_header.dart';
import 'package:silosend/features/home/presentation/widgets/nearby_devices_card.dart';
import 'package:silosend/features/home/presentation/widgets/profile_card.dart';
import 'package:silosend/features/home/presentation/widgets/ready_to_share_card.dart';
import 'package:silosend/features/home/presentation/widgets/receive_button.dart';
import 'package:silosend/features/home/presentation/widgets/send_button.dart';
import 'package:silosend/features/home/presentation/widgets/transfer_card.dart';

/// Main home page composing all home screen widgets.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final devices = const [
      DeviceInfo(
        id: '1',
        name: "Ava's Phone",
        distanceLabel: '1.2 km',
        status: 'Available',
      ),
      DeviceInfo(
        id: '2',
        name: 'Mi Note',
        distanceLabel: '780 m',
        status: 'Available',
      ),
      DeviceInfo(
        id: '3',
        name: "Sam's Tablet",
        distanceLabel: '2.4 km',
        status: 'Connecting',
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  0,
                ),
                child: AppHeader(),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.md,
                  0,
                ),
                child: ProfileCard(deviceName: 'My Device', avatarInitial: 'M'),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.md,
                  0,
                ),
                child: ReadyToShareCard(),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.md,
                  0,
                ),
                child: Row(
                  children: [
                    SendButton(
                      onPressed: () =>
                          GoRouter.of(context).go(AppConstants.routeTransfer),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    ReceiveButton(
                      onPressed: () =>
                          GoRouter.of(context).go(AppConstants.routeDiscovery),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.md,
                  0,
                ),
                child: NearbyDevicesCard(
                  devices: devices,
                  onDeviceTap: (id) {
                    GoRouter.of(context).go(AppConstants.routeConnection);
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.md,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recent Transfers',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TransferCard(
                      fileName: 'Design_Sprint.pdf',
                      peerName: 'Mi Note',
                      direction: TransferDirection.received,
                      state: 'Completed',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TransferCard(
                      fileName: 'Vacation_2025.zip',
                      peerName: "Ava's Phone",
                      direction: TransferDirection.sent,
                      state: 'Sending',
                      progress: 0.65,
                    ),
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
