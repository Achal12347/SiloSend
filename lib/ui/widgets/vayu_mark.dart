import 'package:flutter/material.dart';

import 'package:vayu/ui/theme/vayu_theme.dart';

/// The Vayu mark: the wind symbol on the ink gradient. Used on the startup
/// screen and in onboarding so both match the app icon's colours.
class VayuMark extends StatelessWidget {
  final double size;

  const VayuMark({super.key, this.size = 96});

  @override
  Widget build(BuildContext context) {
    final palette = VayuPalette.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: palette.heroGradient,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(
        Icons.air_rounded,
        color: palette.accentOnInverse,
        size: size * 0.55,
      ),
    );
  }
}
