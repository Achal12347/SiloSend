import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/security/trust_level.dart';

/// Recipient prompt dialog presented when an [IncomingTransferRequest] arrives.
///
/// Strictly separates cryptographic identity trust level from discovery transport,
/// displays truthful file metadata, and provides clear Accept and Decline actions.
class IncomingTransferDialog extends StatelessWidget {
  final IncomingTransferRequest request;
  final AppContainer container;

  const IncomingTransferDialog({
    super.key,
    required this.request,
    required this.container,
  });

  /// Presents the [IncomingTransferDialog] modally.
  static Future<void> show(
    BuildContext context, {
    required IncomingTransferRequest request,
    required AppContainer container,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          IncomingTransferDialog(request: request, container: container),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = request.metadata;

    // Resolve sender device and trust level
    final secureSession =
        container.getSecureSession(request.senderDeviceId) ??
        container.secureSessionManager.getSessionForPeer(
          request.senderDeviceId,
        );
    final trustLevel = secureSession?.trustLevel ?? TrustLevel.unverifiedTOFU;

    // Resolve peer display name
    final peer = container.discoveredPeers.cast<dynamic>().firstWhere(
      (p) => p.deviceId == request.senderDeviceId,
      orElse: () => null,
    );
    final remoteName =
        peer?.displayName ??
        secureSession?.connectionSession.info.remoteDisplayName ??
        'Nearby Device';

    final truncatedId = request.senderDeviceId.length >= 12
        ? '${request.senderDeviceId.substring(0, 8)}...${request.senderDeviceId.substring(request.senderDeviceId.length - 4)}'
        : request.senderDeviceId;

    final transport =
        secureSession?.connectionSession.connection.type ??
        peer?.transportType ??
        TransportType.lan;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.download_rounded,
            color: theme.colorScheme.primary,
            size: 28,
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Incoming File Transfer',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sender info section
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
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
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildTrustBadge(theme, trustLevel),
                    ],
                  ),
                  const SizedBox(height: 4),
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
                      _buildTransportBadge(theme, transport),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // File metadata details
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _resolveFileIcon(meta.fileName, meta.mimeType),
                    size: 32,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meta.fileName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatFileSize(meta.totalBytes),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Save location note
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Save to: Downloads/Vayu/',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () async {
            Navigator.of(context).pop();
            await container.fileSharingCoordinator.declineIncomingTransfer(
              request,
              reason: 'Declined by recipient',
            );
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red.shade700,
            side: BorderSide(color: Colors.red.shade300),
          ),
          child: const Text('Decline'),
        ),
        FilledButton.icon(
          onPressed: () async {
            Navigator.of(context).pop();
            await container.fileSharingCoordinator.acceptIncomingTransfer(
              request,
            );
          },
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('Accept'),
        ),
      ],
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
        label = 'Key Conflict!';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
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

  Widget _buildTransportBadge(ThemeData theme, TransportType transport) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        transport.name.toUpperCase(),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  IconData _resolveFileIcon(String name, String mimeType) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp')) {
      return Icons.image_rounded;
    }
    if (lower.endsWith('.pdf')) {
      return Icons.picture_as_pdf_rounded;
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov')) {
      return Icons.video_file_rounded;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.gz')) {
      return Icons.folder_zip_rounded;
    }
    if (lower.endsWith('.txt') || lower.endsWith('.md')) {
      return Icons.description_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
