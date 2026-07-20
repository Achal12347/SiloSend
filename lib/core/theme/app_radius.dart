import 'package:flutter/material.dart';

/// Consistent border radius values used throughout the SiloSend UI.
class AppRadius {
  const AppRadius._();

  // ── Base Scale ──────────────────────────────────────────────────────
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double full = 999;

  // ── BorderRadius Geometry ───────────────────────────────────────────
  static const BorderRadius radiusXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius radiusSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius radiusMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius radiusLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius radiusXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius radiusFull = BorderRadius.all(
    Radius.circular(full),
  );

  // ── Shape Decorations ───────────────────────────────────────────────
  static RoundedRectangleBorder shapeSm() {
    return RoundedRectangleBorder(borderRadius: radiusSm);
  }

  static RoundedRectangleBorder shapeMd() {
    return RoundedRectangleBorder(borderRadius: radiusMd);
  }

  static RoundedRectangleBorder shapeLg() {
    return RoundedRectangleBorder(borderRadius: radiusLg);
  }

  static RoundedRectangleBorder shapeXl() {
    return RoundedRectangleBorder(borderRadius: radiusXl);
  }

  static RoundedRectangleBorder shapeFull() {
    return RoundedRectangleBorder(borderRadius: radiusFull);
  }
}
