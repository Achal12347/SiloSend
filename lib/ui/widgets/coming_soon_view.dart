import 'package:flutter/material.dart';

import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Honest placeholder for a part of Vayu that is not built yet: says so in
/// one line. No sample content and no list of promised features.
class ComingSoonView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String summary;

  const ComingSoonView({
    super.key,
    required this.icon,
    required this.title,
    required this.summary,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: palette.accentContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(icon, size: 34, color: palette.accent),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: StatusPill(
            label: 'Not available yet',
            foreground: palette.warning,
            background: palette.warningContainer,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          summary,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
