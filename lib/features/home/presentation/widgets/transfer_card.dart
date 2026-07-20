import 'package:flutter/material.dart';
import 'package:silosend/core/theme/app_spacing.dart';
import 'package:silosend/core/widgets/animated_progress_bar.dart';

/// Direction of a file transfer.
enum TransferDirection { sent, received }

/// A card displaying a recent file transfer.
class TransferCard extends StatelessWidget {
  const TransferCard({
    super.key,
    required this.fileName,
    required this.peerName,
    required this.direction,
    required this.state,
    this.progress,
    this.onTap,
  });

  final String fileName;
  final String peerName;
  final TransferDirection direction;
  final String state;
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconData = direction == TransferDirection.sent
        ? Icons.upload
        : Icons.download;
    final directionLabel = direction == TransferDirection.sent
        ? 'Sent'
        : 'Received';

    return Card(
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      iconData,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$directionLabel — $peerName',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    state,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              if (progress != null) ...[
                const SizedBox(height: AppSpacing.sm),
                AnimatedProgressBar(progress: progress!, height: 4),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
