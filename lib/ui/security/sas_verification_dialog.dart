import 'package:flutter/material.dart';

import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/security/crypto_identity_keypair.dart';
import 'package:vayu/domain/security/trust_level.dart';

/// Modal dialog for out-of-band (OOB) Short Authentication String (SAS) verification.
///
/// Allows users to visually or verbally compare deterministic numeric or biometric
/// SAS codes to authenticate peer identity and prevent Man-in-the-Middle (MITM) attacks.
class SasVerificationDialog extends StatefulWidget {
  final SecureSessionImpl session;
  final AppContainer container;

  const SasVerificationDialog({
    super.key,
    required this.session,
    required this.container,
  });

  /// Displays the SAS verification dialog as a modal.
  static Future<void> show(
    BuildContext context, {
    required SecureSessionImpl session,
    required AppContainer container,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) =>
          SasVerificationDialog(session: session, container: container),
    );
  }

  @override
  State<SasVerificationDialog> createState() => _SasVerificationDialogState();
}

class _SasVerificationDialogState extends State<SasVerificationDialog> {
  bool _isProcessing = false;

  String get _formattedNumericSas => widget.session.sas.numeric;

  String get _formattedBiometricWords => widget.session.sas.words;

  String get _remoteFingerprint {
    final raw = widget.session.remoteIdentityPubKey;
    final kp = CryptoIdentityKeypair(publicKey: raw);
    return kp.canonicalFingerprint;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAlreadyVerified =
        widget.session.trustLevel == TrustLevel.sasVerified;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.verified_user_rounded,
            color: isAlreadyVerified
                ? VayuPalette.fromTheme(theme).success
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          const Text('Security Verification'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Compare the security code or words below with the other device. '
              'If both match, your connection is authenticated and immune to Man-in-the-Middle attacks.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // 6-Digit Numeric SAS Code
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.35,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                children: [
                  Text(
                    'NUMERIC CODE',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formattedNumericSas,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 6,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 4-Word Biometric SAS
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                children: [
                  Text(
                    'BIOMETRIC WORDS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formattedBiometricWords,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Peer Fingerprint Info
            Text(
              'Peer Fingerprint',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                _remoteFingerprint,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
              ),
            ),
            const SizedBox(height: 8),

            // Current Trust Status Badge
            Row(
              children: [
                Text(
                  'Trust Status: ',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _trustLevelColor(widget.session.trustLevel)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.session.trustLevel.displayLabel,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _trustLevelColor(widget.session.trustLevel),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isProcessing
              ? null
              : () async {
                  setState(() => _isProcessing = true);
                  await widget.container.disconnectSession(
                    widget.session.sessionId,
                    reason: 'sas_mismatch_rejected_by_user',
                  );
                  if (context.mounted) {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Session disconnected: SAS mismatch rejected',
                        ),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                },
          style: TextButton.styleFrom(
            foregroundColor: VayuPalette.fromTheme(theme).danger,
          ),
          child: const Text('Mismatch / Abort'),
        ),
        FilledButton.icon(
          icon: _isProcessing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded, size: 16),
          label: Text(isAlreadyVerified ? 'Verified' : 'Confirm Match'),
          onPressed: (_isProcessing || isAlreadyVerified)
              ? null
              : () async {
                  setState(() => _isProcessing = true);
                  try {
                    await widget.container.confirmSasVerification(
                      widget.session.sessionId,
                    );
                    if (context.mounted) {
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Identity SAS verified! Peer is trusted.',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to confirm SAS: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  } finally {
                    if (mounted) {
                      setState(() => _isProcessing = false);
                    }
                  }
                },
        ),
      ],
    );
  }

  Color _trustLevelColor(TrustLevel level) {
    final theme = Theme.of(context);
    switch (level) {
      case TrustLevel.sasVerified:
      case TrustLevel.nfcAuthenticated:
        return VayuPalette.fromTheme(theme).success;
      case TrustLevel.trustedTOFU:
        return theme.colorScheme.primary;
      case TrustLevel.unverifiedTOFU:
        return VayuPalette.fromTheme(theme).warning;
      case TrustLevel.keyConflict:
        return VayuPalette.fromTheme(theme).danger;
    }
  }
}
