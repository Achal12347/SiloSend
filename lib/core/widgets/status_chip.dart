import 'package:flutter/material.dart';
import 'package:silosend/core/theme/app_radius.dart';

/// A small chip used to display status (Available, Connecting, etc.).
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chipColor =
        color ??
        switch (label.toLowerCase()) {
          'available' => Colors.green,
          'connecting' => Colors.orange,
          'busy' => Colors.red,
          _ => theme.colorScheme.outline,
        };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: chipColor.withAlpha(25),
        borderRadius: AppRadius.radiusFull,
        border: Border.all(color: chipColor.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: chipColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: chipColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
