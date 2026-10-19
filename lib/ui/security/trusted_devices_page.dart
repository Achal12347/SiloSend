import 'package:flutter/material.dart';

import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/security/crypto_identity_keypair.dart';
import 'package:vayu/domain/security/trust_level.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/security/sas_verification_dialog.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/info_dot.dart';
import 'package:vayu/ui/widgets/trust_label.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Security information (Phase 14): every phone this one has met, how far
/// it is trusted, its key fingerprint, and Verify / Forget.
///
/// The list is the trust store itself (real records only). Forgetting drops
/// the pinned key: the next contact is a first contact again, and that phone
/// cannot reach this one through other phones until they meet directly.
class TrustedDevicesPage extends StatelessWidget {
  final AppContainer container;

  const TrustedDevicesPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TrustedDevicesPage(container: container),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = container.trustStore;
    return Scaffold(
      appBar: AppBar(title: const Text('Trusted devices')),
      body: SafeArea(
        child: StreamBuilder<void>(
          stream: store.changes,
          builder: (context, _) {
            final records = store.records.values.toList()
              ..sort((a, b) {
                // Warnings first, then the most recently seen.
                final aw = a.trustLevel == TrustLevel.keyConflict ? 0 : 1;
                final bw = b.trustLevel == TrustLevel.keyConflict ? 0 : 1;
                if (aw != bw) return aw.compareTo(bw);
                return b.lastSeen.compareTo(a.lastSeen);
              });
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _ThisPhone(container: container),
                const SizedBox(height: 20),
                SectionHeader(title: 'Phones you have met (${records.length})'),
                Card(
                  child: records.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'No phones yet. Phones you connect to appear '
                            'here, with how far each is trusted.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : Column(
                          children: [
                            for (var i = 0; i < records.length; i++) ...[
                              if (i > 0)
                                const Divider(indent: 72, endIndent: 16),
                              _DeviceRow(
                                record: records[i],
                                onTap: () => _showDevice(context, records[i]),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showDevice(BuildContext context, PeerTrustRecord r) {
    return showVayuSheet<void>(
      context: context,
      builder: (sheetContext) => _DeviceSheet(container: container, record: r),
    );
  }
}

String _nameOf(PeerTrustRecord r) =>
    r.displayName ?? 'Phone ${r.deviceIdHex.substring(0, 6)}';

/// The key fingerprint in groups of four, easy to read out and compare.
String _grouped(String hex, {int length = 32}) {
  final part = hex.substring(0, length.clamp(0, hex.length)).toUpperCase();
  return [
    for (var i = 0; i < part.length; i += 4)
      part.substring(i, (i + 4).clamp(0, part.length)),
  ].join(' ');
}

class _ThisPhone extends StatelessWidget {
  final AppContainer container;

  const _ThisPhone({required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = container.localKeypair;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('This phone', style: theme.textTheme.titleMedium),
                ),
                const InfoDot(
                  title: 'Your key fingerprint',
                  message:
                      'Every Vayu phone has its own identity key, kept in '
                      'secure hardware. Other phones remember it the first '
                      'time you connect; if it ever changes they warn about '
                      'it. To be sure no one is in between, compare the code '
                      'shown by Verify on both phones.',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              container.identity?.displayName ?? '',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(
              key == null ? 'Key not loaded' : _grouped(key.fingerprintHex),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 1,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final PeerTrustRecord record;
  final VoidCallback onTap;

  const _DeviceRow({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = TrustLabel.of(context, record.trustLevel);
    return ListTile(
      onTap: onTap,
      leading: DeviceAvatar(name: _nameOf(record), seed: record.deviceIdHex),
      title: Text(
        _nameOf(record),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text('Last seen ${formatWhen(record.lastSeen)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label.icon != null) ...[
            Icon(label.icon, size: 16, color: label.color),
            const SizedBox(width: 4),
          ],
          Text(
            label.text,
            style: theme.textTheme.labelMedium?.copyWith(color: label.color),
          ),
        ],
      ),
    );
  }
}

class _DeviceSheet extends StatelessWidget {
  final AppContainer container;
  final PeerTrustRecord record;

  const _DeviceSheet({required this.container, required this.record});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final label = TrustLabel.of(context, record.trustLevel);
    final session = container.secureSessionManager.getSessionForPeer(
      record.deviceIdHex,
    );
    final conflict = record.trustLevel == TrustLevel.keyConflict;
    final fingerprint = CryptoIdentityKeypair.fromPublicKey(
      record.identityPubKey,
    ).fingerprintHex;
    final explanation = switch (record.trustLevel) {
      TrustLevel.sasVerified || TrustLevel.nfcAuthenticated =>
        'You confirmed this phone (matching codes or a tap). Its key is '
            'remembered.',
      TrustLevel.trustedTOFU =>
        'Met before, with the same key every time. Verify to be sure no one '
            'was in between the first time.',
      TrustLevel.unverifiedTOFU =>
        'Met once. Its key is remembered from then; Verify to be sure it was '
            'really this phone.',
      TrustLevel.keyConflict =>
        'This phone showed a different key than before. Someone may be '
            'pretending to be it, or it was reset or reinstalled. If you know '
            'it was reset, forget it and connect again; otherwise do not.',
    };

    return VayuSheet(
      title: _nameOf(record),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusPill(
            label: label.text,
            icon: label.icon,
            foreground: label.color,
            background: conflict
                ? palette.dangerContainer
                : theme.colorScheme.surfaceContainerHigh,
          ),
          const SizedBox(height: 12),
          Text(explanation, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Text('Key fingerprint', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          SelectableText(
            _grouped(fingerprint),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'First met ${formatWhen(record.firstSeen)} · last seen '
            '${formatWhen(record.lastSeen)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        if (!conflict)
          FilledButton.icon(
            onPressed: session == null
                ? null
                : () {
                    // Opened from the screen, not from this closing sheet.
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    SasVerificationDialog.show(
                      navigator.context,
                      session: session,
                      container: container,
                    );
                  },
            icon: const Icon(Icons.fingerprint_rounded),
            label: Text(session == null ? 'Connect to verify' : 'Verify'),
          ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: palette.danger),
          onPressed: () async {
            final ok = await showVayuConfirm(
              context,
              title: 'Forget ${_nameOf(record)}?',
              message:
                  'Its key is no longer remembered. The next time you '
                  'connect it counts as a new phone, and it cannot reach '
                  'you through other phones until you meet directly again. '
                  'Chats and files stay.',
              confirmLabel: 'Forget',
              destructive: true,
            );
            if (!ok || !context.mounted) return;
            await container.forgetDevice(record.deviceIdHex);
            if (context.mounted) Navigator.of(context).pop();
          },
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Forget'),
        ),
      ],
    );
  }
}
