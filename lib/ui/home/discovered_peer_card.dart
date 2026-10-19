import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/widgets/trust_label.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// One nearby device row: who, how it was found, and a chat button.
///
/// Keeps two facts separate: how the device was found (Wi-Fi / Bluetooth) and
/// whether its cryptographic identity is trusted. Trust is phrased for people
/// ("New device", "Verified") rather than protocol terms. Files are sent from
/// the Send flow, so the row's only action is opening the chat.
class DiscoveredPeerCard extends StatelessWidget {
  final AppContainer container;
  final DiscoveredPeer peer;
  final VoidCallback onChatPressed;

  const DiscoveredPeerCard({
    super.key,
    required this.container,
    required this.peer,
    required this.onChatPressed,
  });

  /// How this phone was actually found ("Wi-Fi", "Bluetooth"), or null.
  /// Only routes with a real address count; nothing is guessed.
  static String? routesLabel(DiscoveredPeer peer) {
    final routes = [
      if (peer.lanEndpoint != null) 'Wi-Fi',
      if (peer.bleEndpoint != null) 'Bluetooth',
    ];
    return routes.isEmpty ? null : routes.join(', ');
  }

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
                    // How it was found, as icons so the line never truncates.
                    if (routesLabel(peer) case final routes?)
                      Semantics(
                        label: 'Found over $routes',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 8),
                            if (peer.lanEndpoint != null)
                              Icon(
                                Icons.wifi_rounded,
                                size: 14,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            if (peer.bleEndpoint != null) ...[
                              const SizedBox(width: 4),
                              Icon(
                                Icons.bluetooth_rounded,
                                size: 14,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Chat with ${peer.displayName}',
            onPressed: onChatPressed,
            icon: const Icon(Icons.chat_bubble_outline_rounded),
          ),
        ],
      ),
    );
  }
}
