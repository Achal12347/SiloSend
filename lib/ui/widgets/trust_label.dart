import 'package:flutter/material.dart';

import 'package:vayu/domain/security/trust_level.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

/// How a peer's cryptographic trust is described to people, everywhere.
///
/// Protocol terms (TOFU, SAS, commitment) stay out of normal UI; Diagnostics
/// and the verification dialog show the details.
class TrustLabel {
  final String text;
  final Color color;
  final IconData? icon;

  const TrustLabel(this.text, this.color, this.icon);

  static TrustLabel of(BuildContext context, TrustLevel? level) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return switch (level) {
      TrustLevel.sasVerified || TrustLevel.nfcAuthenticated => TrustLabel(
        'Verified',
        palette.success,
        Icons.verified_rounded,
      ),
      TrustLevel.trustedTOFU => TrustLabel(
        'Known device',
        theme.colorScheme.onSurfaceVariant,
        null,
      ),
      TrustLevel.keyConflict => TrustLabel(
        'Security warning',
        palette.danger,
        Icons.gpp_maybe_rounded,
      ),
      TrustLevel.unverifiedTOFU || null => TrustLabel(
        'New device',
        theme.colorScheme.onSurfaceVariant,
        null,
      ),
    };
  }
}
