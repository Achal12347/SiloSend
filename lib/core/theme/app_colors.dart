import 'package:flutter/material.dart';

/// Blue / Cyan color palette for the SiloSend UI.
///
/// Follows Material 3 tonal palette conventions.  Every colour here is
/// designed to work on dark and light surfaces.
class AppColors {
  // ── Brand / Accent ──────────────────────────────────────────────────

  static const Color blue = Color(0xFF1976D2);
  static const Color blueLight = Color(0xFF64B5F6);
  static const Color blueDark = Color(0xFF0D47A1);

  static const Color cyan = Color(0xFF00ACC1);
  static const Color cyanLight = Color(0xFF4DD0E1);
  static const Color cyanDark = Color(0xFF00838F);

  // ── Seed colour for ColorScheme.fromSeed ────────────────────────────
  /// Blend of blue and cyan so the generated palette includes both hues.
  static const Color seed = Color(0xFF0D7A9E);

  // ── Glass / Frost ──────────────────────────────────────────────────
  /// Semi-transparent surface colours for glassmorphism overlays.

  static Color glassLight(double opacity) =>
      Colors.white.withAlpha((opacity * 255).round());

  static Color glassDark(double opacity) =>
      Colors.black.withAlpha((opacity * 255).round());

  /// Standard glass surface for dark theme (25 % white).
  static const Color glassSurfaceDark = Color(0x40FFFFFF);

  /// Standard glass surface for light theme (70 % white).
  static const Color glassSurfaceLight = Color(0xB3FFFFFF);

  /// Glass stroke (border).
  static const Color glassStrokeDark = Color(0x1AFFFFFF);
  static const Color glassStrokeLight = Color(0x1A000000);

  // ── Gradients ──────────────────────────────────────────────────────

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [blue, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient primaryGradientVertical = LinearGradient(
    colors: [blue, cyan],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient glassGradientDark = LinearGradient(
    colors: [Color(0x1AFFFFFF), Color(0x0DFFFFFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient glassGradientLight = LinearGradient(
    colors: [Color(0xB3FFFFFF), Color(0x99FFFFFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── Shadows ─────────────────────────────────────────────────────────
  /// Reusable box shadows for glass and elevated surfaces.

  static List<BoxShadow> glassShadow({double elevation = 8}) {
    return [
      BoxShadow(
        color: Colors.black.withAlpha(31),
        blurRadius: elevation,
        offset: Offset(0, elevation * 0.5),
      ),
      BoxShadow(
        color: Colors.black.withAlpha(15),
        blurRadius: elevation * 0.5,
        offset: Offset(0, elevation * 0.25),
      ),
    ];
  }

  static List<BoxShadow> glowShadow() {
    return const [
      BoxShadow(color: Color(0x4000ACC1), blurRadius: 24, spreadRadius: 1),
      BoxShadow(color: Color(0x201976D2), blurRadius: 48, spreadRadius: 2),
    ];
  }
}
