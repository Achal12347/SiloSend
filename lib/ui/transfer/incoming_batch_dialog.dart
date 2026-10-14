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

/// Asks once whether to receive every file of an incoming batch.
///
/// Accepting covers exactly the files listed, from this sender, for this
/// batch; anything else the sender offers later is asked about separately.
class IncomingBatchDialog extends StatefulWidget {
  final IncomingBatchRequest request;
  final AppContainer container;

  const IncomingBatchDialog({
    super.key,
    required this.request,
    required this.container,
  });

  static Future<void> show(
    BuildContext context, {
    required IncomingBatchRequest request,
    required AppContainer container,
  }) {
    return showVayuSheet<void>(
      context: context,
      dismissible: false,
      builder: (_) =>
          IncomingBatchDialog(request: request, container: container),
    );
  }

  @override
  State<IncomingBatchDialog> createState() => _IncomingBatchDialogState();
}

class _IncomingBatchDialogState extends State<IncomingBatchDialog> {
  static const _collapsedCount = 4;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final request = widget.request;
    final container = widget.container;

    final secureSession =
        container.getSecureSession(request.senderDeviceId) ??
        container.secureSessionManager.getSessionForPeer(
          request.senderDeviceId,
        );
    final trustLevel = secureSession?.trustLevel ?? TrustLevel.unverifiedTOFU;
    final trust = TrustLabel.of(context, trustLevel);
    final remoteName =
        container.discoveredPeers
            .where((p) => p.deviceId == request.senderDeviceId)
            .map((p) => p.displayName)
            .firstOrNull ??
        secureSession?.connectionSession.info.remoteDisplayName ??
        'Nearby device';

    final files = request.files;
    final shown = _expanded || files.length <= _collapsedCount + 1
        ? files
        : files.take(_collapsedCount).toList();

    return VayuSheet(
      topPadding: true,
      title: 'Incoming ${files.length} files',
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
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                  child: Text(
                    '${files.length} files · ${formatBytes(request.totalBytes)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                for (final f in shown)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.insert_drive_file_outlined,
                          size: 18,
                          color: theme.colorScheme.secondary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            f.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatBytes(f.sizeBytes),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                if (shown.length < files.length)
                  TextButton(
                    onPressed: () => setState(() => _expanded = true),
                    child: Text('Show ${files.length - shown.length} more'),
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
              Expanded(
                child: Text(
                  'Sent end-to-end encrypted. Accepting covers only these files.',
                  style: theme.textTheme.bodySmall,
                ),
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
            try {
              await container.fileSharingCoordinator.acceptIncomingBatch(
                request,
              );
            } on InsufficientStorageException catch (e) {
              showVayuNotice(
                null,
                messenger: messenger,
                friendlyError(e),
                tone: VayuNoticeTone.problem,
              );
              return;
            } catch (_) {
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
                  batchId: request.batchId,
                ),
              ),
            );
          },
          child: Text('Accept all'),
        ),
        OutlinedButton(
          onPressed: () async {
            Navigator.of(context).pop();
            await container.fileSharingCoordinator.declineIncomingBatch(
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
