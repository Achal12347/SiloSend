import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/contacts/received_cards.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/platform/nfc_card_inbox.dart';
import 'package:vayu/ui/card/card_ring.dart';
import 'package:vayu/ui/card/received_cards_page.dart';
import 'package:vayu/ui/card/vayu_card_view.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Shows a Save / Reject sheet for a card tapped from another phone, on
/// whatever screen is open.
///
/// Cards normally arrive through Android's own NFC tag reader, which runs
/// anyway while the screen is on: it opens Vayu (closed), brings it forward
/// (in the background), or hands it over (open). Vayu runs no reader of its
/// own for this, so waiting for cards costs no extra battery. Cards read by
/// the Send screen's reader are shown the same way.
class IncomingCardWatcher extends StatefulWidget {
  final AppContainer container;

  /// Completes when the container is ready (cards wait until then).
  final Future<void> ready;
  final Widget child;

  const IncomingCardWatcher({
    super.key,
    required this.container,
    required this.ready,
    required this.child,
  });

  @override
  State<IncomingCardWatcher> createState() => _IncomingCardWatcherState();
}

class _IncomingCardWatcherState extends State<IncomingCardWatcher> {
  final List<StreamSubscription<Uint8List>> _subs = [];
  final List<Uint8List> _queue = [];
  bool _showing = false;
  Uint8List? _lastCard;
  DateTime _lastCardAt = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get _enabled =>
      Platform.isAndroid && !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  void initState() {
    super.initState();
    if (_enabled) _start();
  }

  Future<void> _start() async {
    try {
      await widget.ready;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    const inbox = NfcCardInbox();
    _subs
      ..add(inbox.cards.listen(_onCard))
      ..add(widget.container.nfcPairingService.onCardReceived.listen(_onCard));
    final pending = await inbox.takePending();
    if (pending != null) _onCard(pending);
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  void _onCard(Uint8List bytes) {
    if (ContactCard.tryParse(bytes) == null) return;
    // Phones held together are read again and again: one sheet per card.
    final now = DateTime.now();
    final repeat =
        _sameBytes(_lastCard, bytes) &&
        now.difference(_lastCardAt) < const Duration(seconds: 5);
    _lastCardAt = now;
    if (repeat || _queue.any((q) => _sameBytes(q, bytes))) return;
    _lastCard = bytes;
    _queue.add(bytes);
    _showNext();
  }

  Future<void> _showNext() async {
    if (_showing || _queue.isEmpty) return;
    final context = rootNavigatorKey.currentState?.overlay?.context;
    if (context == null) {
      // The app is still building its first screen; try again shortly.
      Timer(const Duration(milliseconds: 300), _showNext);
      return;
    }
    _showing = true;
    final bytes = _queue.removeAt(0);
    try {
      HapticFeedback.mediumImpact();
      await showIncomingCardSheet(
        context,
        container: widget.container,
        vcard: bytes,
      );
    } finally {
      _showing = false;
      _showNext();
    }
  }

  static bool _sameBytes(Uint8List? a, Uint8List b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The Save / Reject sheet for a card received by tap. Save keeps it in
/// Received cards (card history); Reject keeps nothing.
Future<void> showIncomingCardSheet(
  BuildContext context, {
  required AppContainer container,
  required Uint8List vcard,
}) async {
  final card = ContactCard.tryParse(vcard);
  if (card == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final face = CardFace.fromContact(card);
  final save = await showVayuSheet<bool>(
    context: context,
    builder: (sheetContext) => VayuSheet(
      title: 'Card received',
      // Just the card; long-press it to call, email or open the website.
      content: Builder(
        builder: (cardContext) => GestureDetector(
          onLongPress: () =>
              showCardRing(cardContext, container: container, face: face),
          child: VayuCardView(face: face),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(sheetContext).pop(true),
          child: const Text('Save'),
        ),
        TextButton(
          onPressed: () => Navigator.of(sheetContext).pop(false),
          child: const Text('Reject'),
        ),
      ],
    ),
  );
  if (save != true) return;
  // The screen behind the sheet may have closed meanwhile.
  ScaffoldMessengerState? liveMessenger() =>
      messenger != null && messenger.mounted ? messenger : null;
  final store = container.receivedCards;
  if (store == null) return;
  final known = store.all.length;
  final stored = await store.addBytes(vcard, via: ReceivedVia.tap);
  if (stored == null) {
    showVayuNotice(
      null,
      'This card could not be saved.',
      messenger: liveMessenger(),
      tone: VayuNoticeTone.problem,
    );
    return;
  }
  if (store.all.length > known) {
    await container.fileSharingCoordinator.history?.add(
      TransferHistoryRecord(
        transferId: 'tap-${DateTime.now().microsecondsSinceEpoch}',
        outbound: false,
        peerDeviceId: '',
        peerName: stored.name,
        fileName: ContactCard.fileNameFor(stored.name),
        sizeBytes: vcard.length,
        mimeType: 'text/vcard',
        isContact: true,
        outcome: TransferOutcome.completed,
        finishedAt: DateTime.now(),
        savedPath: stored.path,
      ),
    );
  }
  showVayuNotice(
    null,
    'Saved to your card history.',
    messenger: liveMessenger(),
    tone: VayuNoticeTone.success,
    actionLabel: 'View',
    onAction: () {
      final nav = rootNavigatorKey.currentState;
      if (nav != null) {
        nav.push(
          MaterialPageRoute(
            builder: (_) => ReceivedCardsPage(container: container),
          ),
        );
      }
    },
  );
}
