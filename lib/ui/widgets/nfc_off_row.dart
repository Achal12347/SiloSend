import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/permission_report.dart';

/// "NFC is off" with a button to the phone's NFC settings. Screens that use
/// NFC retry when the app comes back to the foreground.
class NfcOffRow extends StatelessWidget {
  final AppContainer container;
  final String message;

  const NfcOffRow({
    super.key,
    required this.container,
    this.message = 'NFC is off. Turn it on to tap phones together.',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          Icons.contactless_outlined,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          onPressed: () =>
              container.platformService.openSettingsPage(SettingsPage.nfc),
          child: const Text('Turn on'),
        ),
      ],
    );
  }
}
