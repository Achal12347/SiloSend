import 'package:flutter/material.dart';
import 'package:vayu/core/contracts/connection_attempt_progress.dart';
import 'package:vayu/core/state/app_container.dart';

/// One quiet line while a connection is being made; nothing once it is up.
class ConnectionAttemptCard extends StatelessWidget {
  final AppContainer container;
  final String? peerId;

  const ConnectionAttemptCard({
    super.key,
    required this.container,
    this.peerId,
  });

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<ConnectionAttemptProgress>(
        stream: container.connectionAttemptStream,
        initialData: container.latestConnectionAttempt,
        builder: (context, snapshot) {
          final progress = snapshot.data;
          if (progress == null ||
              (peerId != null && progress.peerId != peerId) ||
              progress.stage == ConnectionAttemptStage.connected) {
            return const SizedBox.shrink();
          }
          final failed = progress.stage == ConnectionAttemptStage.failed;
          final theme = Theme.of(context);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                if (failed)
                  Icon(
                    Icons.error_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.error,
                  )
                else
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    progress.text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: failed
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
}
