import 'package:flutter/material.dart';

/// Modal dialog providing transparent, truthful rationale for all requested permissions (UI3).
class PermissionsRationaleDialog extends StatelessWidget {
  const PermissionsRationaleDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => const PermissionsRationaleDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.security_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          const Expanded(child: Text('Permission Rationale')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'SiloSend operates entirely offline and peer-to-peer. '
              'Permissions are used strictly for local device communication without any cloud tracking.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _buildPermissionItem(
              theme,
              icon: Icons.bluetooth_searching_rounded,
              title: 'Nearby Devices (Bluetooth)',
              description:
                  'Used to discover and establish direct peer-to-peer radio links with nearby devices. '
                  'SiloSend never tracks your physical location.',
            ),
            const SizedBox(height: 12),
            _buildPermissionItem(
              theme,
              icon: Icons.wifi_rounded,
              title: 'Local Network (Wi-Fi)',
              description:
                  'Used to discover devices on the same Wi-Fi network and transmit data at maximum bandwidth '
                  'over local TCP sockets without going through the internet.',
            ),
            const SizedBox(height: 12),
            _buildPermissionItem(
              theme,
              icon: Icons.folder_rounded,
              title: 'Storage & Downloads',
              description:
                  'Required to read files you choose to send and to save received files into your '
                  'device\'s standard Downloads directory.',
            ),
            const SizedBox(height: 12),
            _buildPermissionItem(
              theme,
              icon: Icons.nfc_rounded,
              title: 'NFC (Optional)',
              description:
                  'Used for instant one-tap pairing and out-of-band key verification between devices.',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }

  Widget _buildPermissionItem(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
