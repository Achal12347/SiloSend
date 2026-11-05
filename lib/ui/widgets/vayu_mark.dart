import 'package:flutter/material.dart';

/// The Vayu mark, identical to the launcher icon: same symbol, colours and
/// proportions in light and dark, so the app and its icon read as one brand.
/// Only this widget draws it; replace the symbol here when the icon changes.
class VayuMark extends StatelessWidget {
  final double size;

  const VayuMark({super.key, this.size = 96});

  // ic_launcher_background and ic_launcher_foreground.
  static const Color background = Color(0xFF000000);
  static const Color symbol = Color(0xFFA9D2C2);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      // The symbol fills about 58% of the width, as on the launcher icon.
      child: Icon(Icons.air, color: symbol, size: size * 0.7),
    );
  }
}
