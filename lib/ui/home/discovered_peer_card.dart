import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/widgets/trust_label.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// One nearby device row.
///
/// Keeps two facts separate: how the device was found (Wi-Fi / Bluetooth) and
/// whether its cryptographic identity is trusted. Trust is phrased for people
/// ("New device", "Verified") rather than protocol terms.
class DiscoveredPeerCard extends StatelessWidget {
  final AppContainer container;
  final DiscoveredPeer peer;
  final bool isConnecting;
  final VoidCallback onConnectPressed;
  final VoidCallback onSendFilePressed;

  /// Optional "Send a contact" menu action.
  final VoidCallback? onSendContactPressed;

  const DiscoveredPeerCard({
    super.key,
    required this.container,
    required this.peer,
    required this.isConnecting,
    required this.onConnectPressed,
    required this.onSendFilePressed,
    this.onSendContactPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final isConnected = container.connectionManager.hasSessionWithDevice(
      peer.deviceId,
    );
    final secureSession =
        container.getSecureSession(peer.deviceId) ??
        container.secureSessionManager.getSessionForPeer(peer.deviceId);
    final trust =
        secureSession?.trustLevel ??
        container.trustStore.getTrustLevel(peer.deviceId);

    final label = TrustLabel.of(context, trust);
    final trustLabel = label.text;
    final trustColor = label.color;
    final trustIcon = label.icon;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          DeviceAvatar(name: peer.displayName, seed: peer.deviceId),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (trustIcon != null) ...[
                      Icon(trustIcon, size: 14, color: trustColor),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        isConnected ? '$trustLabel · Connected' : trustLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: trustColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: onSendFilePressed,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 18),
            ),
            child: const Text('Send'),
          ),
          if (isConnecting)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (value) {
                if (value == 'connect') onConnectPressed();
                if (value == 'contact') onSendContactPressed?.call();
              },
              itemBuilder: (context) => [
                if (onSendContactPressed != null)
                  const PopupMenuItem(
                    value: 'contact',
                    child: Text('Send a contact'),
                  ),
                PopupMenuItem(
                  value: 'connect',
                  enabled: !isConnected,
                  child: Text(isConnected ? 'Connected' : 'Connect'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
