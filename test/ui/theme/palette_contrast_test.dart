import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

/// WCAG contrast for every text-on-colour pair the palette is used for, in
/// both themes. Screen checks only see the states a test happens to show
/// (a sheet, a warning pill); this covers all of them.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';
    final theme = dark ? VayuTheme.dark() : VayuTheme.light();
    final p = dark ? VayuPalette.dark : VayuPalette.light;
    final s = theme.colorScheme;

    test('$name: status text on its tint reads at 4.5:1', () {
      for (final (label, fg, bg) in [
        ('success', p.success, p.successContainer),
        ('warning', p.warning, p.warningContainer),
        ('danger', p.danger, p.dangerContainer),
        ('accent', p.accent, p.accentContainer),
      ]) {
        expect(
          _contrast(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$label on its container',
        );
      }
    });

    test('$name: text on filled colours reads at 4.5:1', () {
      for (final (label, fg, bg) in [
        ('onPrimary', s.onPrimary, s.primary),
        ('onSecondary', s.onSecondary, s.secondary),
        ('onTertiary', s.onTertiary, s.tertiary),
        ('onError (destructive buttons)', s.onError, s.error),
        ('onSurface', s.onSurface, s.surface),
        ('onSurfaceVariant', s.onSurfaceVariant, s.surface),
      ]) {
        expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: label);
      }
    });

    test('$name: status colours read as text on the page', () {
      for (final (label, c) in [
        ('success', p.success),
        ('warning', p.warning),
        ('danger', p.danger),
        ('accent', p.accent),
      ]) {
        expect(
          _contrast(c, s.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$label on the page',
        );
      }
    });
  }

  test('avatar initials (large bold text) read at 3:1 on every hue', () {
    for (final hue in [158, 24, 212, 284, 44, 336, 112, 190]) {
      final color = HSLColor.fromAHSL(1, hue.toDouble(), 0.24, 0.46).toColor();
      expect(
        _contrast(Colors.white, color),
        greaterThanOrEqualTo(3.0),
        reason: 'hue $hue',
      );
    }
  });
}
