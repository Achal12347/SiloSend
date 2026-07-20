import 'dart:ui';
import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Glassmorphism decoration utilities for the SiloSend UI.
///
/// Provides ready-to-use [BoxDecoration] and [BackdropFilter] helpers
/// that create the frosted-glass look described in the UI spec.
class GlassEffect {
  const GlassEffect._();

  // ── Box Decoration ──────────────────────────────────────────────────

  /// Dark-theme glass container decoration.
  static BoxDecoration dark({
    double blur = 16,
    double elevation = 8,
    double borderRadius = 16,
    Color? borderColor,
  }) {
    return BoxDecoration(
      gradient: AppColors.glassGradientDark,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: borderColor ?? AppColors.glassStrokeDark,
        width: 0.5,
      ),
      boxShadow: AppColors.glassShadow(elevation: elevation),
    );
  }

  /// Light-theme glass container decoration.
  static BoxDecoration light({
    double blur = 16,
    double elevation = 8,
    double borderRadius = 16,
    Color? borderColor,
  }) {
    return BoxDecoration(
      gradient: AppColors.glassGradientLight,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(
        color: borderColor ?? AppColors.glassStrokeLight,
        width: 0.5,
      ),
      boxShadow: AppColors.glassShadow(elevation: elevation),
    );
  }

  // ── Backdrop Filter ─────────────────────────────────────────────────

  /// Wraps [child] in a frosted-glass backdrop filter.
  static Widget blur({required Widget child, double sigma = 12}) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: child,
      ),
    );
  }

  // ── Adaptive Helper ─────────────────────────────────────────────────

  /// Returns the appropriate glass decoration for the current brightness.
  static BoxDecoration adaptive(
    BuildContext context, {
    double blur = 16,
    double elevation = 8,
    double borderRadius = 16,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark
        ? dark(blur: blur, elevation: elevation, borderRadius: borderRadius)
        : light(blur: blur, elevation: elevation, borderRadius: borderRadius);
  }
}
