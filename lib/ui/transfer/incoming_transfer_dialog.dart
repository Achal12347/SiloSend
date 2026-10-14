import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/security/trust_level.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/widgets/trust_label.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Asks the user to accept or decline an incoming file or contact (UI6).
///
/// Shows who is sending in human terms (name and trust), what is coming, and
/// a clear warning when the sender's identity key has changed.
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
    return showVayuSheet<void>(
      context: context,
      dismissible: false,
      builder: (dialogContext) =>
          IncomingTransferDialog(request: request, container: container),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final meta = request.metadata;
    final isContact = meta.payloadType == PayloadType.contact;

    final secureSession =
        container.getSecureSession(request.senderDeviceId) ??
        container.secureSessionManager.getSessionForPeer(
          request.senderDeviceId,
        );
    final trustLevel = secureSession?.trustLevel ?? TrustLevel.unverifiedTOFU;
    final trust = TrustLabel.of(context, trustLevel);

    final peerName = container.discoveredPeers
        .where((p) => p.deviceId == request.senderDeviceId)
        .map((p) => p.displayName)
        .firstOrNull;
    final remoteName =
        peerName ??
        secureSession?.connectionSession.info.remoteDisplayName ??
        'Nearby device';

    final itemName = isContact
        ? meta.fileName.replaceAll(RegExp(r'\.vcf$', caseSensitive: false), '')
        : meta.fileName;

    return VayuSheet(
      topPadding: true,
      title: isContact ? 'Incoming contact' : 'Incoming file',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              DeviceAvatar(
                name: remoteName,
                seed: request.senderDeviceId,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(remoteName, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (trust.icon != null) ...[
                          Icon(trust.icon, size: 14, color: trust.color),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          trust.text,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: trust.color,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  isContact
                      ? Icons.person_outline_rounded
                      : Icons.insert_drive_file_outlined,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        itemName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isContact
                            ? 'Contact card · ${formatBytes(meta.totalBytes)}'
                            : formatBytes(meta.totalBytes),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (trustLevel == TrustLevel.keyConflict) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.dangerContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'This device\'s identity changed since you last connected. '
                'Decline unless you know it was reinstalled or reset.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 14,
                color: theme.colorScheme.secondary,
              ),
              const SizedBox(width: 6),
              Text(
                'Sent end-to-end encrypted',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () async {
            HapticFeedback.selectionClick();
            final navigator = Navigator.of(context);
            final messenger = ScaffoldMessenger.maybeOf(context);
            navigator.pop();
            final TransferTask task;
            try {
              task = await container.fileSharingCoordinator
                  .acceptIncomingTransfer(request);
            } on InsufficientStorageException catch (e) {
              showVayuNotice(
                null,
                messenger: messenger,
                friendlyError(e),
                tone: VayuNoticeTone.problem,
              );
              return;
            } catch (e) {
              showVayuNotice(
                null,
                messenger: messenger,
                'Couldn\'t start receiving. Please try again.',
                tone: VayuNoticeTone.problem,
              );
              return;
            }
            navigator.push(
              MaterialPageRoute(
                builder: (_) => TransferDetailPage(
                  container: container,
                  transferId: task.transferId,
                ),
              ),
            );
          },
          child: const Text('Accept'),
        ),
        OutlinedButton(
          onPressed: () async {
            Navigator.of(context).pop();
            await container.fileSharingCoordinator.declineIncomingTransfer(
              request,
              reason: 'Declined by recipient',
            );
          },
          child: const Text('Decline'),
        ),
      ],
    );
  }
}
