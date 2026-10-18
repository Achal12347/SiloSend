import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/card/vayu_card_view.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

/// Long-press on a card: the card lifts in place over a dimmed screen and
/// small rounded-square icons appear just outside it (delete and save above
/// its corners; call, email and website below). Icons only, no text. Tap outside or press
/// back to close. Only actions the card has are shown.
Future<void> showCardRing(
  BuildContext cardContext, {
  required AppContainer container,
  required CardFace face,
  String? savedPath,
  Future<void> Function()? onDelete,
}) {
  final box = cardContext.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Future.value();
  final rect = MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
  HapticFeedback.mediumImpact();
  return Navigator.of(cardContext).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      barrierLabel: 'Close',
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, animation, _) => _CardRing(
        rect: rect,
        face: face,
        animation: animation,
        container: container,
        savedPath: savedPath,
        onDelete: onDelete,
      ),
    ),
  );
}

class _CardRing extends StatelessWidget {
  final Rect rect;
  final CardFace face;
  final Animation<double> animation;
  final AppContainer container;
  final String? savedPath;
  final Future<void> Function()? onDelete;

  static const double _button = 40;
  static const double _gap = 10;
  static const double _lift = 1.04;

  const _CardRing({
    required this.rect,
    required this.face,
    required this.animation,
    required this.container,
    this.savedPath,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final palette = VayuPalette.of(context);
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    );

    void close() => Navigator.of(context).pop();

    void act(Future<void> Function() action) {
      close();
      action();
    }

    final open = container.platformService.openUri;
    final phone = face.phoneUri;
    final email = face.emailUri;
    final website = face.websiteUri;
    final links = <Widget>[
      if (phone != null)
        _RingButton(
          icon: Icons.call_rounded,
          label: 'Call',
          onTap: () => act(() => open(phone)),
        ),
      if (email != null)
        _RingButton(
          icon: Icons.mail_rounded,
          label: 'Email',
          onTap: () => act(() => open(email)),
        ),
      if (website != null)
        _RingButton(
          icon: Icons.language_rounded,
          label: 'Website',
          onTap: () => act(() => open(website)),
        ),
    ];

    // Icons sit just outside the lifted card's edges, never on it: delete
    // and save above its corners, links below its middle. Near the top or
    // bottom of the screen a row moves to the other side.
    final grow = rect.height * (_lift - 1) / 2;
    final aboveRow = rect.top - grow - _gap - _button;
    final belowRow = rect.bottom + grow + _gap;
    final roomAbove = aboveRow >= padding.top + 4;
    final roomBelow = belowRow + _button <= screen.height - padding.bottom - 4;
    final actionsTop = roomAbove ? aboveRow : belowRow;
    final linksTop = roomBelow ? belowRow : aboveRow;

    Widget pop(Widget child) => ScaleTransition(scale: curve, child: child);

    return Stack(
      children: [
        // Taps outside the card and icons close the ring.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: close,
          ),
        ),
        Positioned.fromRect(
          rect: rect,
          child: ScaleTransition(
            scale: Tween<double>(begin: 1, end: _lift).animate(curve),
            child: IgnorePointer(child: VayuCardView(face: face)),
          ),
        ),
        if (onDelete != null)
          Positioned(
            left: rect.left,
            top: actionsTop,
            child: pop(
              _RingButton(
                icon: Icons.delete_rounded,
                label: 'Delete',
                color: palette.danger,
                onTap: () => act(onDelete!),
              ),
            ),
          ),
        if (savedPath != null)
          Positioned(
            left: rect.right - _button,
            top: actionsTop,
            child: pop(
              _RingButton(
                icon: Icons.person_add_alt_1_rounded,
                label: 'Save to contacts',
                color: palette.success,
                onTap: () => act(
                  () => container.platformService.openFile(
                    savedPath!,
                    mimeType: 'text/x-vcard',
                  ),
                ),
              ),
            ),
          ),
        if (links.isNotEmpty)
          Positioned(
            left: rect.left,
            width: rect.width,
            top: linksTop,
            child: pop(
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < links.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    links[i],
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A small rounded-square icon with no visible text; the label is for screen readers and
/// the long-press tooltip.
class _RingButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _RingButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: label,
      child: Material(
        color: theme.colorScheme.surface,
        // Rounded rectangle, echoing the card's corners.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: _CardRing._button,
            height: _CardRing._button,
            child: Icon(
              icon,
              size: 20,
              color: color ?? theme.colorScheme.onSurface,
              semanticLabel: label,
            ),
          ),
        ),
      ),
    );
  }
}
