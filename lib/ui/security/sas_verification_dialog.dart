import 'package:flutter/material.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/security/crypto_identity_keypair.dart';
import 'package:vayu/domain/security/trust_level.dart';

/// Bottom sheet for comparing the safety words (SAS) shown on both phones.
///
/// If they match, nobody is intercepting the connection and the peer becomes
/// verified; if not, the session is closed.
class SasVerificationDialog extends StatefulWidget {
  final SecureSessionImpl session;
  final AppContainer container;

  const SasVerificationDialog({
    super.key,
    required this.session,
    required this.container,
  });

  /// Opens the safety check sheet.
  static Future<void> show(
    BuildContext context, {
    required SecureSessionImpl session,
    required AppContainer container,
  }) {
    return showVayuSheet<void>(
      context: context,
      builder: (ctx) =>
          SasVerificationDialog(session: session, container: container),
    );
  }

  @override
  State<SasVerificationDialog> createState() => _SasVerificationDialogState();
}

class _SasVerificationDialogState extends State<SasVerificationDialog> {
  bool _isProcessing = false;
  bool _showDetails = false;

  String get _remoteFingerprint {
    final raw = widget.session.remoteIdentityPubKey;
    final kp = CryptoIdentityKeypair(publicKey: raw);
    return kp.canonicalFingerprint;
  }

  Future<void> _reject() async {
    setState(() => _isProcessing = true);
    final navigator = Navigator.of(context);
    await widget.container.disconnectSession(
      widget.session.sessionId,
      reason: 'sas_mismatch_rejected_by_user',
    );
    navigator.pop();
    showVayuNotice(
      null,
      'Disconnected. The safety words did not match.',
      tone: VayuNoticeTone.problem,
    );
  }

  Future<void> _confirm() async {
    setState(() => _isProcessing = true);
    final navigator = Navigator.of(context);
    try {
      await widget.container.confirmSasVerification(widget.session.sessionId);
      navigator.pop();
      showVayuNotice(null, 'Verified', tone: VayuNoticeTone.success);
    } catch (e) {
      AppLogger.warning('SasVerification', 'Confirm failed: $e');
      showVayuNotice(null, friendlyError(e), tone: VayuNoticeTone.problem);
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final verified = widget.session.trustLevel == TrustLevel.sasVerified;

    return VayuSheet(
      title: verified ? 'Verified' : 'Check the safety words',
      message: verified
          ? 'You already confirmed this device.'
          : 'Make sure the other phone shows the same words.',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Text(
                  widget.session.sas.words,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.session.sas.numeric,
                  style: theme.textTheme.titleMedium?.copyWith(
                    letterSpacing: 4,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _showDetails = !_showDetails),
              child: Text(_showDetails ? 'Hide details' : 'Details'),
            ),
          ),
          if (_showDetails)
            SelectableText(
              'Device fingerprint\n$_remoteFingerprint',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      actions: [
        if (!verified)
          FilledButton(
            onPressed: _isProcessing ? null : _confirm,
            child: const Text('They match'),
          ),
        TextButton(
          onPressed: _isProcessing
              ? null
              : verified
              ? () => Navigator.of(context).pop()
              : _reject,
          style: verified
              ? null
              : TextButton.styleFrom(foregroundColor: palette.danger),
          child: Text(verified ? 'Close' : 'They don\'t match'),
        ),
      ],
    );
  }
}
