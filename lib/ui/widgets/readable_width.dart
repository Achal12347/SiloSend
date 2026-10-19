import 'package:flutter/material.dart';

/// Keeps the app at a readable width on wide screens (tablets, landscape,
/// foldables, later Windows): centred, at most [maxWidth], on the page
/// background. Phones are unchanged.
///
/// The [MediaQuery] size is narrowed too, so widgets that size themselves
/// from the screen (chat bubbles, sheets) follow the visible width.
class ReadableWidth extends StatelessWidget {
  static const double maxWidth = 840;

  final Widget child;

  const ReadableWidth({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= maxWidth) return child;
        final media = MediaQuery.of(context);
        return ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: Center(
            child: SizedBox(
              width: maxWidth,
              child: MediaQuery(
                data: media.copyWith(size: Size(maxWidth, media.size.height)),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Whether the layout has room for side navigation instead of a bottom bar.
bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 600;
