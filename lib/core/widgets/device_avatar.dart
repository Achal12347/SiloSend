import 'package:flutter/material.dart';

/// An avatar widget representing a device with an optional online indicator.
class DeviceAvatar extends StatelessWidget {
  const DeviceAvatar({
    super.key,
    required this.name,
    this.size = 48,
    this.isOnline = true,
    this.imageUrl,
  });

  final String name;
  final double size;
  final bool isOnline;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';

    final avatar = CircleAvatar(
      radius: size / 2,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: imageUrl != null
          ? ClipOval(
              child: Image.network(
                imageUrl!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _buildInitials(theme, initials),
              ),
            )
          : _buildInitials(theme, initials),
    );

    return Stack(
      children: [
        avatar,
        Positioned(
          bottom: 2,
          right: 2,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: isOnline ? Colors.green : Colors.grey,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInitials(ThemeData theme, String initials) {
    return Text(
      initials,
      style: theme.textTheme.titleMedium?.copyWith(
        color: theme.colorScheme.onPrimaryContainer,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
