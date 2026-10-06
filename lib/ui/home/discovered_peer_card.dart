import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/security/trust_level.dart';

/// Renders a discovered nearby peer device card.
///
/// Strictly maintains architectural separation between:
/// 1. Discovery Transport (how presence was discovered, e.g. LAN vs BLE)
/// 2. Cryptographic Trust Level (authenticated identity, e.g. SAS vs TOFU)
class DiscoveredPeerCard extends StatelessWidget {
  final AppContainer container;
  final DiscoveredPeer peer;
  final bool isConnecting;
  final VoidCallback onConnectPressed;
  final VoidCallback onSendFilePressed;

  const DiscoveredPeerCard({
    super.key,
    required this.container,
    required this.peer,
    required this.isConnecting,
    required this.onConnectPressed,
    required this.onSendFilePressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final truncatedId = peer.deviceId.length >= 12
        ? '${peer.deviceId.substring(0, 8)}...${peer.deviceId.substring(peer.deviceId.length - 4)}'
        : peer.deviceId;

    final isConnected = container.connectionManager.hasSessionWithDevice(
      peer.deviceId,
    );

    // Resolve security trust level if an authenticated session exists
    final secureSession =
        container.getSecureSession(peer.deviceId) ??
        container.secureSessionManager.getSessionForPeer(peer.deviceId);
    final trustLevel = secureSession?.trustLevel;

    return Container(
      margin: const EdgeInsets.only(bottom: 10.0),
      padding: const EdgeInsets.all(14.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  peer.displayName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _buildDiscoveryTransportBadge(theme, peer.transportType),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ID: $truncatedId',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
              if (trustLevel != null)
                _buildTrustBadge(theme, trustLevel)
              else
                _buildTrustBadge(theme, TrustLevel.unverifiedTOFU),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 4,
                children: peer.availableTransports.map((t) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      t.name.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  );
                }).toList(),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    onPressed: onSendFilePressed,
                    icon: const Icon(Icons.send_rounded, size: 14),
                    label: const Text('Send File'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isConnected)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.green.shade300),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            size: 13,
                            color: Colors.green.shade700,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Connected',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.green.shade800,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    FilledButton.tonalIcon(
                      onPressed: isConnecting ? null : onConnectPressed,
                      icon: isConnecting
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link_rounded, size: 15),
                      label: Text(isConnecting ? 'Connecting...' : 'Connect'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoveryTransportBadge(
    ThemeData theme,
    TransportType transport,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Discovered via ${transport.name.toUpperCase()}',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget _buildTrustBadge(ThemeData theme, TrustLevel trustLevel) {
    Color color;
    String label;

    switch (trustLevel) {
      case TrustLevel.sasVerified:
        color = Colors.green.shade700;
        label = 'SAS Verified';
        break;
      case TrustLevel.nfcAuthenticated:
        color = Colors.teal.shade700;
        label = 'NFC Verified';
        break;
      case TrustLevel.trustedTOFU:
        color = Colors.blue.shade700;
        label = 'Trusted (TOFU)';
        break;
      case TrustLevel.unverifiedTOFU:
        color = Colors.orange.shade800;
        label = 'Not Verified';
        break;
      case TrustLevel.keyConflict:
        color = Colors.red.shade700;
        label = 'Key Conflict';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
