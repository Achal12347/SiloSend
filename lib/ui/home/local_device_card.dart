import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// How this phone appears to others, with a rename action.
///
/// Device ID, protocol version and key fingerprint are in Diagnostics; they
/// mean nothing to most people and crowded the home screen.
class LocalDeviceCard extends StatelessWidget {
  final AppContainer container;

  const LocalDeviceCard({super.key, required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<LocalDeviceIdentity>(
      stream: container.identityStream,
      initialData: container.identity,
      builder: (context, idSnapshot) {
        final identity = idSnapshot.data;
        final displayName = identity?.displayName ?? 'This phone';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(title: 'Your device'),
            Card(
              child: StreamBuilder<DiscoveryStatus>(
                stream: container.discoveryStatusStream,
                initialData: container.discoveryStatus,
                builder: (context, statusSnapshot) {
                  final visible =
                      (statusSnapshot.data ?? DiscoveryStatus.idle).isActive;
                  return ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    leading: DeviceAvatar(
                      name: displayName,
                      seed: identity?.idHex ?? displayName,
                    ),
                    title: Text(
                      displayName,
                      style: theme.textTheme.titleMedium,
                    ),
                    subtitle: Text(
                      visible
                          ? 'Visible to nearby devices'
                          : 'Hidden while search is paused',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Change Device Name',
                      onPressed: () =>
                          _showEditNameDialog(context, displayName),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _showEditNameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Change Device Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(
            labelText: 'Device Name',
            hintText: 'Name nearby devices will see',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                // Re-advertises so nearby phones see the new name immediately.
                await container.updateCustomDisplayName(newName);
              }
              if (dialogCtx.mounted) {
                Navigator.of(dialogCtx).pop();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
