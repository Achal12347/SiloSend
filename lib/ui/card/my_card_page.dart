import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/nfc_pairing_service.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/ui/card/edit_card_page.dart';
import 'package:vayu/ui/card/received_cards_page.dart';
import 'package:vayu/ui/card/vayu_card_view.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/pairing/qr_code_view.dart';
import 'package:vayu/ui/profile/profile_widgets.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/widgets/peer_picker_sheet.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

enum _TapState { checking, ready, nfcOff, noNfc }

/// The user's card and the three ways to share it: tap (NFC), QR, or send
/// to a nearby phone.
///
/// The card is served over NFC only while this screen is open; leaving the
/// screen stops it.
class MyCardPage extends StatefulWidget {
  final AppContainer container;

  const MyCardPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MyCardPage(container: container)),
      );

  @override
  State<MyCardPage> createState() => _MyCardPageState();
}

class _MyCardPageState extends State<MyCardPage> with WidgetsBindingObserver {
  StreamSubscription<VayuCard?>? _cardSub;
  _TapState _tap = _TapState.checking;
  bool _serving = false;

  NfcPairingService get _nfc => widget.container.nfcPairingService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cardSub = widget.container.myCardStream.listen((_) {
      if (!mounted) return;
      setState(() {});
      _serve();
    });
    _serve();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the NFC settings page: share by tap now.
    if (state == AppLifecycleState.resumed && _tap != _TapState.ready) {
      _serve();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cardSub?.cancel();
    if (_serving) _nfc.stopSharing();
    super.dispose();
  }

  Future<void> _serve() async {
    final card = widget.container.myCard;
    if (card == null) return;
    final result = await _nfc.shareCard(card.toVcard());
    if (!mounted) {
      if (result.isSuccess) _nfc.stopSharing();
      return;
    }
    setState(() {
      _serving = result.isSuccess;
      _tap = switch (result.status) {
        NfcOperationStatus.success => _TapState.ready,
        NfcOperationStatus.hardwareDisabled => _TapState.nfcOff,
        _ => _TapState.noNfc,
      };
    });
  }

  String _receivedLabel() {
    final count = widget.container.receivedCards?.all.length ?? 0;
    return count == 0 ? 'Received cards' : 'Received cards ($count)';
  }

  Future<void> _showQr(VayuCard card) {
    // The QR holds the vCard itself, so any phone camera can save it.
    return showVayuSheet<void>(
      context: context,
      builder: (sheetContext) => VayuSheet(
        title: 'Scan to save',
        message: 'Works with any phone camera, even without Vayu.',
        content: Center(
          child: QrCodeView(
            data: utf8.decode(card.toVcard()),
            size: 260,
            semanticLabel: 'QR code with your card',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendNearby(VayuCard card) async {
    final peer = await pickNearbyPeer(
      context,
      container: widget.container,
      title: 'Send your card to',
    );
    if (peer == null || !mounted) return;
    try {
      final task = await widget.container.fileSharingCoordinator
          .sendContactToPeer(peer, name: card.name, vcard: card.toVcard());
      if (mounted) {
        await TransferDetailPage.open(context, widget.container, task: task);
      }
    } catch (e) {
      AppLogger.warning('MyCard', 'Sending card failed: $e');
      if (mounted) {
        showVayuNotice(
          context,
          friendlyError(e, peerName: peer.displayName),
          tone: VayuNoticeTone.problem,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = widget.container.myCard;

    if (card == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Icon(
                  Icons.badge_outlined,
                  size: 64,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(height: 20),
                Text(
                  'Your profile',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Start with your name. Share it as a card with a tap; it stays on this phone until you do.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: 54,
                  child: FilledButton(
                    onPressed: () => showProfileSetupSheet(
                      context,
                      container: widget.container,
                    ),
                    child: const Text('Set up your profile'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit card',
            onPressed: () => EditCardPage.open(context, widget.container),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            VayuCardView(face: CardFace.fromCard(card)),
            _NextStep(
              card: card,
              onAdd: () => EditCardPage.open(context, widget.container),
            ),
            const SizedBox(height: 20),
            _TapStatus(state: _tap, container: widget.container),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => _showQr(card),
              icon: const Icon(Icons.qr_code_2_rounded),
              label: const Text('Show QR code'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _sendNearby(card),
              icon: const Icon(Icons.send_rounded),
              label: const Text('Send to a nearby phone'),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () =>
                  ReceivedCardsPage.open(context, widget.container),
              icon: const Icon(Icons.contacts_outlined),
              label: Text(_receivedLabel()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Suggests the single next profile step, until the profile is complete.
class _NextStep extends StatelessWidget {
  final VayuCard card;
  final VoidCallback onAdd;

  const _NextStep({required this.card, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ProfileProgress.of(card);
    final text = switch (progress.next) {
      ProfileStep.reach =>
        'Add a phone number or email so people can reach you',
      ProfileStep.work => 'Add your job title or company',
      ProfileStep.name || null => null,
    };
    if (text == null) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onAdd,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    value: progress.fraction,
                    strokeWidth: 3,
                    color: theme.colorScheme.secondary,
                    backgroundColor: theme.colorScheme.outlineVariant,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
                TextButton(onPressed: onAdd, child: const Text('Add')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TapStatus extends StatelessWidget {
  final _TapState state;
  final AppContainer container;

  const _TapStatus({required this.state, required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String title, String body) = switch (state) {
      _TapState.ready => (
        Icons.nfc_rounded,
        'Ready to tap',
        'Hold the backs of the phones together, near the cameras.',
      ),
      _TapState.nfcOff => (
        Icons.nfc_rounded,
        'NFC is off',
        'Turn it on to share by tap, or show the QR code.',
      ),
      _TapState.noNfc => (
        Icons.qr_code_2_rounded,
        'No tap on this phone',
        'Show the QR code or send your card to a nearby phone.',
      ),
      _TapState.checking => (Icons.nfc_rounded, 'Getting ready…', ''),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, size: 32, color: theme.colorScheme.secondary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (state == _TapState.nfcOff)
            TextButton(
              onPressed: () =>
                  container.platformService.openSettingsPage(SettingsPage.nfc),
              child: const Text('Turn on'),
            ),
        ],
      ),
    );
  }
}
