import 'package:flutter/material.dart';
import 'package:silosend/core/theme/app_radius.dart';
import 'package:silosend/core/theme/app_spacing.dart';
import 'package:silosend/core/widgets/glass_container.dart';
import 'package:silosend/features/home/presentation/widgets/device_tile.dart';

/// A card showing a list of nearby discoverable devices.
class NearbyDevicesCard extends StatelessWidget {
  const NearbyDevicesCard({
    super.key,
    this.devices = const [],
    this.onDeviceTap,
  });

  final List<DeviceInfo> devices;
  final void Function(String deviceId)? onDeviceTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GlassContainer(
      padding: const EdgeInsets.all(AppSpacing.md),
      borderRadius: AppRadius.lg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Nearby Devices',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${devices.length} found',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.search_off,
                      size: 32,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'No devices found',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ...devices.map(
              (device) => DeviceTile(
                name: device.name,
                distanceLabel: device.distanceLabel,
                status: device.status,
                onTap: () => onDeviceTap?.call(device.id),
              ),
            ),
        ],
      ),
    );
  }
}

/// Device information displayed in the nearby devices card.
class DeviceInfo {
  final String id;
  final String name;
  final String distanceLabel;
  final String status;

  const DeviceInfo({
    required this.id,
    required this.name,
    required this.distanceLabel,
    required this.status,
  });
}
