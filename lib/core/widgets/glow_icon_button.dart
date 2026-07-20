import 'package:flutter/material.dart';
import 'package:silosend/core/theme/app_radius.dart';

/// An icon button wrapped in a glowing glass container.
class GlowIconButton extends StatelessWidget {
  const GlowIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.size = 48,
    this.iconSize = 22,
    this.glowColor,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;
  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveGlowColor =
        glowColor ?? theme.colorScheme.primary.withAlpha(60);

    final button = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.radiusMd,
        boxShadow: [
          BoxShadow(color: effectiveGlowColor, blurRadius: 12, spreadRadius: 1),
        ],
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: iconSize),
        color: theme.colorScheme.primary,
        tooltip: tooltip,
      ),
    );

    return button;
  }
}
