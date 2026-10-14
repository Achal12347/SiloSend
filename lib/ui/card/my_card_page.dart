import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/nfc_pairing_service.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/ui/card/edit_card_page.dart';
import 'package:vayu/ui/card/vayu_card_view.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/pairing/qr_code_view.dart';
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

class _MyCardPageState extends State<MyCardPage> {
  StreamSubscription<VayuCard?>? _cardSub;
  _TapState _tap = _TapState.checking;
  bool _serving = false;

  NfcPairingService get _nfc => widget.container.nfcPairingService;

  @override
  void initState() {
    super.initState();
    _cardSub = widget.container.myCardStream.listen((_) {
      if (!mounted) return;
      setState(() {});
      _serve();
    });
    _serve();
  }

  @override
  void dispose() {
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
        appBar: AppBar(title: const Text('My card')),
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
                  'Your card',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Share your contact details with a tap. It stays on this phone until you share it.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: 54,
                  child: FilledButton(
                    onPressed: () =>
                        EditCardPage.open(context, widget.container),
                    child: const Text('Create your card'),
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
        title: const Text('My card'),
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
            const SizedBox(height: 28),
            _TapStatus(state: _tap),
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
          ],
        ),
      ),
    );
  }
}

class _TapStatus extends StatelessWidget {
  final _TapState state;

  const _TapStatus({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String title, String body) = switch (state) {
      _TapState.ready => (
        Icons.nfc_rounded,
        'Ready to tap',
        'Hold the back of your phone to another phone with Vayu open.',
      ),
      _TapState.nfcOff => (
        Icons.nfc_rounded,
        'NFC is off',
        'Turn on NFC in your phone\'s settings to share by tap.',
      ),
      _TapState.noNfc => (
        Icons.qr_code_2_rounded,
        'No tap on this phone',
        'Use the QR code or send it to a nearby phone.',
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
        ],
      ),
    );
  }
}

/// Bottom sheet for a card received by tap: preview, then save via the
/// phone's contacts app (the user confirms there).
Future<void> showReceivedCardSheet(
  BuildContext context, {
  required AppContainer container,
  required ContactCard card,
  required Future<void> Function() onSave,
}) {
  return showVayuSheet<void>(
    context: context,
    builder: (sheetContext) => VayuSheet(
      title: 'Card received',
      content: VayuCardView(face: CardFace.fromContact(card)),
      actions: [
        FilledButton(
          onPressed: () async {
            Navigator.of(sheetContext).pop();
            await onSave();
          },
          child: const Text('Save to contacts'),
        ),
        TextButton(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
