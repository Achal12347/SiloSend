import 'package:flutter/material.dart';

/// Small shared building blocks so screens share one visual language.

/// Section title used on the home screen instead of nested card headers.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final Widget? leading;

  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium,
              semanticsLabel: title,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Circular initial avatar whose hue is derived from the device ID, so the
/// same phone always gets the same color without storing anything.
class DeviceAvatar extends StatelessWidget {
  final String name;
  final String seed;
  final double size;

  const DeviceAvatar({
    super.key,
    required this.name,
    required this.seed,
    this.size = 44,
  });

  // Hues spaced around the wheel at one shared saturation and lightness, so
  // every avatar has equal visual weight and none reads as a raw primary.
  static const List<double> _hues = [158, 24, 212, 284, 44, 336, 112, 190];

  static Color _avatarColor(int hash) {
    final hue = _hues[hash % _hues.length];
    return HSLColor.fromAHSL(1, hue, 0.24, 0.46).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final hash = seed.codeUnits.fold<int>(
      0,
      (h, c) => (h * 31 + c) & 0x7fffffff,
    );
    final color = _avatarColor(hash);
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? '?'
        : trimmed.characters.first.toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color, Color.lerp(color, Colors.black, 0.18)!],
          ),
        ),
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Compact rounded label with an optional leading icon.
class StatusPill extends StatelessWidget {
  final String label;
  final Color foreground;
  final Color background;
  final IconData? icon;

  const StatusPill({
    super.key,
    required this.label,
    required this.foreground,
    required this.background,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
