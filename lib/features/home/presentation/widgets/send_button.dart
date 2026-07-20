import 'package:flutter/material.dart';
import 'package:silosend/core/theme/app_radius.dart';
import 'package:silosend/core/theme/app_spacing.dart';
import 'package:silosend/core/widgets/glass_container.dart';

/// Large send button with glassmorphism style.
class SendButton extends StatelessWidget {
  const SendButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Expanded(
      child: GestureDetector(
        onTap: onPressed,
        child: GlassContainer(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
          borderRadius: AppRadius.lg,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.arrow_upward_rounded,
                  color: theme.colorScheme.onPrimary,
                  size: 24,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Send',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Files & more',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
