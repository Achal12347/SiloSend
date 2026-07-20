import 'package:flutter/material.dart';

/// Text style presets for the SiloSend UI.
///
/// Builds on Material 3's type scale but adds convenience presets
/// commonly used throughout the app.
class AppTypography {
  const AppTypography._();

  // ── Font Family ─────────────────────────────────────────────────────
  static const String fontFamily = 'Inter';

  // ── Presets ─────────────────────────────────────────────────────────
  /// Large display heading for hero sections (e.g. splash / welcome).
  static TextStyle displayLarge({required BuildContext context}) {
    return Theme.of(context).textTheme.displayLarge ?? const TextStyle();
  }

  /// Section headings used on Home, Discovery, etc.
  static TextStyle sectionTitle({required BuildContext context}) {
    return (Theme.of(context).textTheme.titleMedium ?? const TextStyle())
        .copyWith(fontWeight: FontWeight.w600);
  }

  /// Card titles (e.g. device name, file name).
  static TextStyle cardTitle({required BuildContext context}) {
    return Theme.of(context).textTheme.titleSmall ?? const TextStyle();
  }

  /// Subtle body text used for labels, timestamps, distance.
  static TextStyle caption({required BuildContext context}) {
    return Theme.of(context).textTheme.bodySmall ?? const TextStyle();
  }

  /// Button label with medium weight.
  static TextStyle buttonLabel({required BuildContext context}) {
    return (Theme.of(context).textTheme.labelLarge ?? const TextStyle())
        .copyWith(fontWeight: FontWeight.w600);
  }
}
