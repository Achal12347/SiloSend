import 'package:flutter/material.dart';

import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Explains, in a bottom sheet, why Vayu asks for each permission (UI3).
class PermissionsRationaleDialog extends StatelessWidget {
  const PermissionsRationaleDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showVayuSheet<void>(
      context: context,
      builder: (_) => const PermissionsRationaleDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return VayuSheet(
      title: 'Why Vayu asks for permissions',
      message: 'Everything stays between nearby phones. No account, no cloud.',
      content: Column(
        children: [
          _item(
            theme,
            Icons.bluetooth_searching_rounded,
            'Nearby devices',
            'Find and connect to phones near you. Vayu never tracks your location.',
          ),
          _item(
            theme,
            Icons.wifi_rounded,
            'Wi-Fi',
            'Send files fast over Wi-Fi, without using the internet.',
          ),
          _item(
            theme,
            Icons.folder_outlined,
            'Files',
            'Open the files you choose and save the ones you receive.',
          ),
          _item(
            theme,
            Icons.nfc_rounded,
            'NFC (optional)',
            'Pair or share your card with a tap.',
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }

  Widget _item(ThemeData theme, IconData icon, String title, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.secondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
