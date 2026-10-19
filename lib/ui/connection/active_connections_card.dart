import 'package:flutter/material.dart';

import 'package:vayu/ui/widgets/vayu_widgets.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/security/trust_level.dart';
import 'package:vayu/ui/security/sas_verification_dialog.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/friendly_error.dart';

/// Renders real-time active point-to-point connection sessions and disconnect actions.
class ActiveConnectionsCard extends StatelessWidget {
  final AppContainer container;

  const ActiveConnectionsCard({super.key, required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<List<ConnectionSession>>(
      stream: container.activeSessionsStream,
      initialData: container.activeSessions,
      builder: (context, snapshot) {
        final sessions = snapshot.data ?? [];

        return Card(
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
                          Icons.link_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Active Connections',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    if (sessions.isNotEmpty)
                      StatusPill(
                        label: '${sessions.length} Active',
                        foreground: VayuPalette.fromTheme(theme).success,
                        background: VayuPalette.fromTheme(theme)
                            .successContainer,
                      ),
                  ],
                ),
                const Divider(height: 20),
                if (sessions.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12.0),
                      child: Text(
                        'No active peer connections.\nTap "Connect" on a discovered peer or use Out-of-Band Pairing.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                else
                  StreamBuilder<SecureSessionImpl>(
                    stream: container.secureSessionsStream,
                    builder: (context, _) {
                      return Column(
                        children: sessions
                            .map(
                              (session) =>
                                  _buildSessionItem(context, theme, session),
                            )
                            .toList(),
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

  Widget _buildSessionItem(
    BuildContext context,
    ThemeData theme,
    ConnectionSession session,
  ) {
    final info = session.info;
    final remoteName = info.remoteDisplayName ?? 'Nearby device';
    final remoteId = info.remoteDeviceId;

    final isLan = info.activeTransport == TransportType.lan;
    DiscoveredPeer? discoveredPeer;
    for (final peer in container.discoveredPeers) {
      if (peer.deviceId == remoteId) {
        discoveredPeer = peer;
        break;
      }
    }
    final sendPeer = discoveredPeer;

    return Container(
      margin: const EdgeInsets.only(bottom: 8.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
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
                  remoteName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.send_rounded, size: 14),
                    label: const Text('Send File'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                    ),
                    onPressed: sendPeer == null
                        ? null
                        : () async {
                            try {
                              await container.fileSharingCoordinator
                                  .sendFileToPeer(sendPeer);
                            } catch (e) {
                              if (context.mounted) {
                                showVayuNotice(
                                  context,
                                  friendlyError(e),
                                  tone: VayuNoticeTone.problem,
                                );
                              }
                            }
                          },
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.close_rounded, size: 14),
                    label: const Text('Disconnect'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: VayuPalette.fromTheme(theme).danger,
                      side: BorderSide(
                        color: VayuPalette.fromTheme(theme).dangerContainer,
                      ),
                    ),
                    onPressed: () async {
                      await container.disconnectSession(
                        session.sessionId,
                        reason: 'Disconnected by user',
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isLan
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  routeName(info.activeTransport, info.remoteAddress),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isLan
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildSecurityStatus(context, theme, session),
        ],
      ),
    );
  }

  Widget _buildSecurityStatus(
    BuildContext context,
    ThemeData theme,
    ConnectionSession session,
  ) {
    final secureSession = container.getSecureSession(session.sessionId);
    final isSecured =
        session.state == SessionState.secured && secureSession != null;

    if (isSecured) {
      final trustLevel = secureSession.trustLevel;
      final trustColor = _trustLevelColor(Theme.of(context), trustLevel);

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.lock_rounded,
              size: 14,
              color: VayuPalette.fromTheme(theme).success,
            ),
            const SizedBox(width: 4),
            Text(
              'AES-256-GCM',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: VayuPalette.fromTheme(theme).success,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: trustColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                trustLevel.displayLabel,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: trustColor,
                ),
              ),
            ),
            const Spacer(),
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () {
                SasVerificationDialog.show(
                  context,
                  session: secureSession,
                  container: container,
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.fingerprint_rounded,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      'Verify SAS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (session.state == SessionState.handshaking) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Securing communication channel...',
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.info_outline,
            size: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            'Transport link established (Phase 5 unauthenticated)',
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Color _trustLevelColor(ThemeData theme, TrustLevel level) {
    switch (level) {
      case TrustLevel.sasVerified:
      case TrustLevel.nfcAuthenticated:
        return VayuPalette.fromTheme(theme).success;
      case TrustLevel.trustedTOFU:
        return theme.colorScheme.primary;
      case TrustLevel.unverifiedTOFU:
        return VayuPalette.fromTheme(theme).warning;
      case TrustLevel.keyConflict:
        return VayuPalette.fromTheme(theme).danger;
    }
  }
}

/// The route a connection really uses, in user terms. TCP over a Wi-Fi
/// Direct group is told apart by Android's fixed group subnet.
String routeName(TransportType transport, String? remoteAddress) =>
    switch (transport) {
      TransportType.ble => 'Bluetooth',
      TransportType.wifiDirect => 'Wi-Fi Direct',
      // "via Bo" is the first relay's name (RelayedConnection).
      TransportType.relay =>
        (remoteAddress?.startsWith('via ') ?? false)
            ? 'Through ${remoteAddress!.substring(4)}'
            : 'Through another phone',
      TransportType.lan =>
        (remoteAddress?.startsWith('192.168.49.') ?? false)
            ? 'Wi-Fi Direct'
            : 'Wi-Fi',
    };
