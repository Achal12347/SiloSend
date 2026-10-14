import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/widgets/rename_device_sheet.dart';
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
                    // Only worth saying when nearby phones cannot see you.
                    subtitle: visible
                        ? null
                        : Text(
                            'Hidden while search is paused',
                            style: theme.textTheme.bodySmall,
                          ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Change name',
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
    showRenameDeviceSheet(
      context,
      container: container,
      currentName: currentName,
    );
  }
}
