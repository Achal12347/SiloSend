import 'package:flutter/material.dart';

import 'package:vayu/ui/theme/vayu_theme.dart';

/// App-wide messenger, so notices can be shown from places without a page
/// context (for example the crash catcher). Attached in `MaterialApp`.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

enum VayuNoticeTone { neutral, success, problem }

/// Short notice attached to the bottom edge (never floating mid-screen).
///
/// One style for the whole app. Keep [message] to one short sentence.
/// After an `await`, pass a [messenger] captured before it instead of a
/// context.
void showVayuNotice(
  BuildContext? context,
  String message, {
  VayuNoticeTone tone = VayuNoticeTone.neutral,
  String? actionLabel,
  VoidCallback? onAction,
  ScaffoldMessengerState? messenger,
}) {
  final target =
      messenger ??
      (context != null ? ScaffoldMessenger.maybeOf(context) : null) ??
      rootMessengerKey.currentState;
  if (target == null) return;
  final theme = Theme.of(context ?? target.context);
  final palette = VayuPalette.fromTheme(theme);
  final icon = switch (tone) {
    VayuNoticeTone.success => Icons.check_circle_rounded,
    VayuNoticeTone.problem => Icons.error_outline_rounded,
    VayuNoticeTone.neutral => null,
  };
  final iconColor = switch (tone) {
    VayuNoticeTone.success => palette.accentOnInverse,
    VayuNoticeTone.problem => palette.accentOnInverse,
    VayuNoticeTone.neutral => null,
  };
  target
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
            ],
            Expanded(child: Text(message)),
          ],
        ),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
}

/// Opens a sheet that rises from the bottom edge.
///
/// [dismissible] false keeps the sheet up until the user picks an action
/// (for decisions such as accepting an incoming file).
Future<T?> showVayuSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    showDragHandle: dismissible,
    builder: (sheetContext) => Padding(
      // Lift content above the keyboard for sheets with text fields.
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: builder(sheetContext),
    ),
  );
}

/// Standard sheet layout: title, optional message, content, then actions
/// stacked full width (primary on top) so they are easy to reach.
class VayuSheet extends StatelessWidget {
  final String title;
  final String? message;
  final Widget? content;
  final List<Widget> actions;

  /// Extra top space when the sheet has no drag handle.
  final bool topPadding;

  const VayuSheet({
    super.key,
    required this.title,
    this.message,
    this.content,
    this.actions = const [],
    this.topPadding = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, topPadding ? 24 : 0, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (content != null) ...[const SizedBox(height: 20), content!],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 24),
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                actions[i],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Asks a yes/no question in a bottom sheet. Returns true only on confirm.
Future<bool> showVayuConfirm(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showVayuSheet<bool>(
    context: context,
    builder: (sheetContext) {
      final palette = VayuPalette.of(sheetContext);
      return VayuSheet(
        title: title,
        message: message,
        actions: [
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: palette.danger,
                    foregroundColor: Colors.white,
                  )
                : null,
            onPressed: () => Navigator.of(sheetContext).pop(true),
            child: Text(confirmLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(false),
            child: Text(cancelLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
