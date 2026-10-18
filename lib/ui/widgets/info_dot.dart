import 'package:flutter/material.dart';

import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// A small accent "i". Tap or long-press shows [message] in a short sheet
/// from the bottom, so screens stay short and the current screen stays put.
class InfoDot extends StatelessWidget {
  final String title;
  final String message;

  /// Color for the "i" on dark surfaces (the home hero).
  final Color? color;

  const InfoDot({
    super.key,
    required this.title,
    required this.message,
    this.color,
  });

  void _show(BuildContext context) => showInfoSheet(context, title, message);

  @override
  Widget build(BuildContext context) {
    final tint = color ?? VayuPalette.of(context).accent;
    return Semantics(
      button: true,
      label: 'About $title',
      excludeSemantics: true,
      child: InkResponse(
        onTap: () => _show(context),
        onLongPress: () => _show(context),
        radius: 18,
        child: Padding(
          // Larger touch target than the dot itself.
          padding: const EdgeInsets.all(8),
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: tint, width: 1.4),
            ),
            child: Text(
              'i',
              style: TextStyle(
                color: tint,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The short explanation sheet used by [InfoDot].
Future<void> showInfoSheet(BuildContext context, String title, String message) {
  return showVayuSheet<void>(
    context: context,
    builder: (sheetContext) => VayuSheet(
      title: title,
      message: message,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}
