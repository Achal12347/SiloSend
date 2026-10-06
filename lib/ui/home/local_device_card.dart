import 'package:flutter/material.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';

/// Renders the local device identity, cryptographic key fingerprint,
/// and live transport readiness status (LAN & BLE).
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
        final displayName = identity?.displayName ?? 'Your Device';
        final fullHex = identity?.idHex ?? '';
        final truncatedId = fullHex.length >= 12
            ? '${fullHex.substring(0, 8)}...${fullHex.substring(fullHex.length - 4)}'
            : fullHex;

        return Card(
          elevation: 0,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.devices_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Your Device',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      tooltip: 'Change Device Name',
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          _showEditNameDialog(context, displayName),
                    ),
                  ],
                ),
                const Divider(height: 16),
                _buildInfoRow(
                  theme: theme,
                  label: 'Device Name',
                  value: displayName,
                  bold: true,
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  theme: theme,
                  label: 'Device ID',
                  value: truncatedId.isNotEmpty ? truncatedId : 'Assigning...',
                  tooltip: identity?.uuid,
                ),
                const SizedBox(height: 8),
                _buildInfoRow(
                  theme: theme,
                  label: 'Protocol',
                  value:
                      'v${identity?.protocolVersion ?? AppConstants.protocolVersion}',
                ),
                if (container.localKeypair != null) ...[
                  const SizedBox(height: 8),
                  _buildInfoRow(
                    theme: theme,
                    label: 'Security Fingerprint',
                    value: container.localKeypair!.fingerprintHex.length >= 16
                        ? '${container.localKeypair!.fingerprintHex.substring(0, 16)}...'
                        : container.localKeypair!.fingerprintHex,
                    tooltip: container.localKeypair!.canonicalFingerprint,
                  ),
                ],
                const SizedBox(height: 14),
                // Live Transport Readiness Badges
                StreamBuilder<SystemCapabilities>(
                  stream: container.capabilitiesStream,
                  initialData: container.systemCapabilities,
                  builder: (context, capSnapshot) {
                    final caps =
                        capSnapshot.data ?? container.systemCapabilities;
                    return Row(
                      children: [
                        _buildReadinessChip(
                          theme,
                          label: 'LAN',
                          isReady: caps.canUseLan,
                          statusText: caps.canUseLan ? 'Ready' : 'Disconnected',
                        ),
                        const SizedBox(width: 8),
                        _buildReadinessChip(
                          theme,
                          label: 'BLE',
                          isReady: caps.canUseBle,
                          statusText: caps.canUseBle
                              ? 'Ready'
                              : (caps.isBluetoothOff
                                    ? 'Off'
                                    : (caps.isNearbyPermissionMissing
                                          ? 'Permission Needed'
                                          : 'Unavailable')),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildReadinessChip(
    ThemeData theme, {
    required String label,
    required bool isReady,
    required String statusText,
  }) {
    final color = isReady ? Colors.green.shade700 : Colors.amber.shade900;
    final bg = isReady ? Colors.green.shade50 : Colors.amber.shade50;
    final border = isReady ? Colors.green.shade200 : Colors.amber.shade200;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isReady ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            '$label: $statusText',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required ThemeData theme,
    required String label,
    required String value,
    bool bold = false,
    String? tooltip,
  }) {
    Widget valueWidget = Text(
      value,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      ),
    );

    if (tooltip != null) {
      valueWidget = Tooltip(message: tooltip, child: valueWidget);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        valueWidget,
      ],
    );
  }

  void _showEditNameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Change Device Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(
            labelText: 'Device Name',
            hintText: 'Enter name visible to nearby devices',
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
                await container.identityManager.updateDisplayName(newName);
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
