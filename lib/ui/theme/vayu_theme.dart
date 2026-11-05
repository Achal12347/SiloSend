import 'package:flutter/material.dart';

/// Vayu visual identity: "paper and ink, with a breath of sage".
///
/// Color system (60 / 30 / 10):
/// * 60% warm neutrals. Light uses an ivory paper ground, dark uses a warm ink
///   ground. Warm greys read calmer and more premium than pure white/black.
/// * 30% monochrome ink for primary actions and emphasis (inverted in dark).
/// * 10% one restrained accent: a desaturated sage (hue ~160°, ~25% saturation),
///   with a split-complementary clay (hue ~25°) used only for small highlights.
/// Status colors share the accent's muted saturation (jade, ochre, brick), so
/// nothing on screen is a raw primary color. Widgets read every color from
/// [ColorScheme] or [VayuPalette]; nothing hard-codes a Material shade.
class VayuTheme {
  VayuTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final palette = isDark ? VayuPalette.dark : VayuPalette.light;

    final ink = isDark ? const Color(0xFFECE9E3) : const Color(0xFF1A1B1E);
    final onInk = isDark ? const Color(0xFF141517) : const Color(0xFFF7F5F0);

    final scheme = ColorScheme(
      brightness: brightness,
      // Primary = ink: buttons and emphasis stay monochrome.
      primary: ink,
      onPrimary: onInk,
      primaryContainer: isDark
          ? const Color(0xFF2A2C30)
          : const Color(0xFFE8E4DC),
      onPrimaryContainer: isDark
          ? const Color(0xFFE4E1DA)
          : const Color(0xFF26272A),
      // Secondary = sage accent: progress, live states, selection.
      secondary: palette.accent,
      onSecondary: isDark ? const Color(0xFF0F1A16) : Colors.white,
      secondaryContainer: palette.accentContainer,
      onSecondaryContainer: isDark
          ? const Color(0xFFD5E8E0)
          : const Color(0xFF233A31),
      tertiary: palette.clay,
      // Ink on the light dark-mode clay: white was 2.4:1 there.
      onTertiary: isDark ? const Color(0xFF0F1A16) : Colors.white,
      tertiaryContainer: isDark
          ? const Color(0xFF3A2A20)
          : const Color(0xFFF1E3D8),
      onTertiaryContainer: isDark
          ? const Color(0xFFF0DCCD)
          : const Color(0xFF4A2E1E),
      error: palette.danger,
      // Dark ink on the light dark-mode danger: white was 2.25:1 there.
      onError: isDark ? const Color(0xFF3F2220) : Colors.white,
      errorContainer: palette.dangerContainer,
      onErrorContainer: isDark
          ? const Color(0xFFF3D3CF)
          : const Color(0xFF4D1D19),
      surface: isDark ? const Color(0xFF0F1011) : const Color(0xFFF5F3EE),
      onSurface: ink,
      onSurfaceVariant: isDark
          ? const Color(0xFFA29E97)
          : const Color(0xFF66625B),
      surfaceContainerLowest: isDark
          ? const Color(0xFF0B0C0D)
          : const Color(0xFFFFFFFF),
      surfaceContainerLow: isDark
          ? const Color(0xFF17181A)
          : const Color(0xFFFFFFFF),
      surfaceContainer: isDark
          ? const Color(0xFF1C1D20)
          : const Color(0xFFEFECE6),
      surfaceContainerHigh: isDark
          ? const Color(0xFF222326)
          : const Color(0xFFE9E5DE),
      surfaceContainerHighest: isDark
          ? const Color(0xFF292A2E)
          : const Color(0xFFE2DED6),
      outline: isDark ? const Color(0xFF4A4C50) : const Color(0xFFC9C3B8),
      outlineVariant: isDark
          ? const Color(0xFF26282B)
          : const Color(0xFFE4DFD6),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: isDark
          ? const Color(0xFFECE9E3)
          : const Color(0xFF1F2023),
      onInverseSurface: isDark
          ? const Color(0xFF1A1B1E)
          : const Color(0xFFF2EFE9),
      inversePrimary: isDark
          ? const Color(0xFF1A1B1E)
          : const Color(0xFFECE9E3),
      surfaceTint: Colors.transparent,
    );

    final radius = BorderRadius.circular(16);
    final typography = Typography.material2021(
      platform: TargetPlatform.android,
    );
    final textTheme = _textTheme(
      typography.englishLike.merge(
        isDark ? typography.white : typography.black,
      ),
      scheme,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      extensions: [palette],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 46),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 46),
          foregroundColor: scheme.onSurface,
          shape: RoundedRectangleBorder(borderRadius: radius),
          side: BorderSide(color: scheme.outline),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurface,
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: textTheme.labelLarge,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainer,
        labelStyle: textTheme.labelMedium,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: radius),
        iconColor: scheme.onSurfaceVariant,
        selectedColor: scheme.secondary,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.secondary, width: 1.5),
        ),
      ),
      // Notices are attached to the bottom edge, never floating mid-screen.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.fixed,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: palette.accentOnInverse,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.secondary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: radius),
          selectedBackgroundColor: scheme.secondaryContainer,
          selectedForegroundColor: scheme.onSecondaryContainer,
          side: BorderSide(color: scheme.outline),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.onSecondary : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.secondary : null,
        ),
      ),
      // Bottom navigation: quiet surface, sage pill marks the current tab.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => textTheme.labelMedium?.copyWith(
            color: s.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    TextStyle? tone(TextStyle? s, FontWeight w, [double spacing = 0]) =>
        s?.copyWith(
          fontWeight: w,
          letterSpacing: spacing,
          color: scheme.onSurface,
        );
    return base.copyWith(
      displaySmall: tone(base.displaySmall, FontWeight.w600, -1.0),
      headlineMedium: tone(base.headlineMedium, FontWeight.w600, -0.8),
      headlineSmall: tone(base.headlineSmall, FontWeight.w600, -0.5),
      titleLarge: tone(base.titleLarge, FontWeight.w600, -0.3),
      titleMedium: tone(base.titleMedium, FontWeight.w600, -0.1),
      titleSmall: tone(base.titleSmall, FontWeight.w600),
      labelLarge: tone(base.labelLarge, FontWeight.w600, 0.2),
      labelMedium: tone(base.labelMedium, FontWeight.w600, 0.3),
      labelSmall: base.labelSmall?.copyWith(
        letterSpacing: 1.1,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        color: scheme.onSurface,
        height: 1.45,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        color: scheme.onSurface,
        height: 1.4,
      ),
      bodySmall: base.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
  }
}

/// Brand and status colors that [ColorScheme] does not model.
@immutable
class VayuPalette extends ThemeExtension<VayuPalette> {
  /// Deep ink card used for the home hero (dark on light, lifted on dark).
  final LinearGradient heroGradient;
  final Color heroBorder;

  final Color onHero;
  final Color onHeroMuted;

  final Color accent;
  final Color accentContainer;
  final Color accentOnInverse;
  final Color clay;

  final Color success;
  final Color successContainer;
  final Color warning;
  final Color warningContainer;
  final Color danger;
  final Color dangerContainer;

  const VayuPalette({
    required this.heroGradient,
    required this.heroBorder,
    required this.onHero,
    required this.onHeroMuted,
    required this.accent,
    required this.accentContainer,
    required this.accentOnInverse,
    required this.clay,
    required this.success,
    required this.successContainer,
    required this.warning,
    required this.warningContainer,
    required this.danger,
    required this.dangerContainer,
  });

  static const light = VayuPalette(
    heroGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF1D1F23), Color(0xFF2B2E33)],
    ),
    heroBorder: Color(0xFF34373D),
    onHero: Color(0xFFF4F1EA),
    onHeroMuted: Color(0xFFB9B5AC),
    // Darkened from 4F7F6E / 9A7136 to reach WCAG 4.5:1 for text on every
    // light surface (paper, white and grouped surfaces).
    accent: Color(0xFF446E5F),
    accentContainer: Color(0xFFDCE8E1),
    accentOnInverse: Color(0xFFA9D2C2),
    clay: Color(0xFF9B6A49),
    success: Color(0xFF387157),
    successContainer: Color(0xFFDDEBE2),
    warning: Color(0xFF815F2D),
    warningContainer: Color(0xFFF3E7D2),
    danger: Color(0xFFA14941),
    dangerContainer: Color(0xFFF5DEDA),
  );

  static const dark = VayuPalette(
    heroGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF1B1D20), Color(0xFF25282C)],
    ),
    heroBorder: Color(0xFF33363B),
    onHero: Color(0xFFF1EEE8),
    onHeroMuted: Color(0xFFA9A59D),
    accent: Color(0xFF8DBDAB),
    accentContainer: Color(0xFF213A31),
    accentOnInverse: Color(0xFF3F7F62),
    clay: Color(0xFFD29C78),
    success: Color(0xFF86C2A2),
    successContainer: Color(0xFF1D3328),
    warning: Color(0xFFD9B37A),
    warningContainer: Color(0xFF3A2E1B),
    danger: Color(0xFFE29B92),
    dangerContainer: Color(0xFF3F2220),
  );

  static VayuPalette of(BuildContext context) =>
      Theme.of(context).extension<VayuPalette>() ?? light;

  static VayuPalette fromTheme(ThemeData theme) =>
      theme.extension<VayuPalette>() ?? light;

  @override
  VayuPalette copyWith({
    LinearGradient? heroGradient,
    Color? heroBorder,
    Color? onHero,
    Color? onHeroMuted,
    Color? accent,
    Color? accentContainer,
    Color? accentOnInverse,
    Color? clay,
    Color? success,
    Color? successContainer,
    Color? warning,
    Color? warningContainer,
    Color? danger,
    Color? dangerContainer,
  }) {
    return VayuPalette(
      heroGradient: heroGradient ?? this.heroGradient,
      heroBorder: heroBorder ?? this.heroBorder,
      onHero: onHero ?? this.onHero,
      onHeroMuted: onHeroMuted ?? this.onHeroMuted,
      accent: accent ?? this.accent,
      accentContainer: accentContainer ?? this.accentContainer,
      accentOnInverse: accentOnInverse ?? this.accentOnInverse,
      clay: clay ?? this.clay,
      success: success ?? this.success,
      successContainer: successContainer ?? this.successContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      danger: danger ?? this.danger,
      dangerContainer: dangerContainer ?? this.dangerContainer,
    );
  }

  @override
  VayuPalette lerp(ThemeExtension<VayuPalette>? other, double t) {
    if (other is! VayuPalette) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return VayuPalette(
      heroGradient: LinearGradient.lerp(heroGradient, other.heroGradient, t)!,
      heroBorder: c(heroBorder, other.heroBorder),
      onHero: c(onHero, other.onHero),
      onHeroMuted: c(onHeroMuted, other.onHeroMuted),
      accent: c(accent, other.accent),
      accentContainer: c(accentContainer, other.accentContainer),
      accentOnInverse: c(accentOnInverse, other.accentOnInverse),
      clay: c(clay, other.clay),
      success: c(success, other.success),
      successContainer: c(successContainer, other.successContainer),
      warning: c(warning, other.warning),
      warningContainer: c(warningContainer, other.warningContainer),
      danger: c(danger, other.danger),
      dangerContainer: c(dangerContainer, other.dangerContainer),
    );
  }
}

/// One look for the Vayu business card: background, a soft glow, and text
/// colours chosen for that background.
@immutable
class CardStyle {
  final String name;
  final LinearGradient gradient;
  final Color glow;
  final Color onCard;
  final Color onCardMuted;

  const CardStyle({
    required this.name,
    required this.gradient,
    required this.glow,
    required this.onCard,
    required this.onCardMuted,
  });
}

/// Card styles: deep, muted tones plus one light card. The same in light and
/// dark mode so a card looks the same on every phone. The order is stored
/// on the card, so new styles are only ever added at the end; earlier
/// positions keep their meaning (2 was a flat clay, now Bronze; 3 slate, now
/// Midnight; 4 plum, now Wine).
class VayuCardColors {
  VayuCardColors._();

  static const List<CardStyle> styles = [
    CardStyle(
      name: 'Ink',
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2E3136), Color(0xFF141518)],
      ),
      glow: Color(0xFF6E9C8B),
      onCard: Color(0xFFF4F1EA),
      onCardMuted: Color(0xFFB9B5AC),
    ),
    CardStyle(
      name: 'Forest',
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2F5C4D), Color(0xFF172F27)],
      ),
      glow: Color(0xFF8FC4AE),
      onCard: Color(0xFFF1F5F1),
      onCardMuted: Color(0xFFB5CBBF),
    ),
    CardStyle(
      name: 'Bronze',
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF6B5536), Color(0xFF2E2416)],
      ),
      glow: Color(0xFFD9B77A),
      onCard: Color(0xFFF7F0E2),
      onCardMuted: Color(0xFFD2C2A2),
    ),
    CardStyle(
      name: 'Midnight',
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2B3B58), Color(0xFF121A2B)],
      ),
      glow: Color(0xFF8EA6D6),
      onCard: Color(0xFFEEF1F7),
      onCardMuted: Color(0xFFAEB9CF),
    ),
    CardStyle(
      name: 'Wine',
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF5C2E3C), Color(0xFF2A141C)],
      ),
      glow: Color(0xFFD891A6),
      onCard: Color(0xFFF7ECEF),
      onCardMuted: Color(0xFFD1AEB8),
    ),
    CardStyle(
      name: 'Pearl',
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFF4F1EA), Color(0xFFDCD5C7)],
      ),
      glow: Color(0xFFFFFFFF),
      onCard: Color(0xFF1E1F22),
      onCardMuted: Color(0xFF5E5A53),
    ),
  ];

  static CardStyle of(int index) => styles[index.clamp(0, styles.length - 1)];
}
