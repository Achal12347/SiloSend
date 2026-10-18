import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:vayu/core/contacts/received_cards.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/platform/qr_scanner.dart';
import 'package:vayu/ui/card/card_ring.dart';
import 'package:vayu/ui/card/vayu_card_view.dart';
import 'package:vayu/ui/widgets/camera_access.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Card history: the cards themselves, close together. When the list is
/// longer than the screen, the card in focus pops out as you scroll (focus
/// runs from the first card to the last); a short list stays still.
/// Long-press a card for icons around it: delete, save, call, email, web.
class ReceivedCardsPage extends StatefulWidget {
  final AppContainer container;

  const ReceivedCardsPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReceivedCardsPage(container: container),
        ),
      );

  @override
  State<ReceivedCardsPage> createState() => _ReceivedCardsPageState();
}

class _ReceivedCardsPageState extends State<ReceivedCardsPage> {
  final ScrollController _scroll = ScrollController();

  static const double _gap = 12;
  static const double _side = 20;
  static const double _ends = 12;
  final Map<String, CardFace> _faces = {};

  ReceivedCards? get _store => widget.container.receivedCards;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Reads each card file once; faces are kept for smooth scrolling.
  Future<void> _loadFaces(List<ReceivedCard> cards) async {
    final store = _store;
    if (store == null) return;
    var changed = false;
    for (final card in cards) {
      if (_faces.containsKey(card.id)) continue;
      final contents = await store.read(card);
      _faces[card.id] = contents == null
          ? CardFace(name: card.name, role: card.organization)
          : CardFace.fromContact(contents);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  void _ring(BuildContext cardContext, ReceivedCard card) {
    final face = _faces[card.id];
    if (face == null) return;
    showCardRing(
      cardContext,
      container: widget.container,
      face: face,
      savedPath: card.path,
      onDelete: () async {
        _faces.remove(card.id);
        await _store?.remove(card.id);
      },
    );
  }

  /// Scans the QR code on another phone's My card and keeps that card here.
  Future<void> _scanCard() async {
    final store = _store;
    if (store == null) return;
    if (!await ensureCameraAccess(context, widget.container)) return;
    final String? text;
    try {
      text = await const QrScanner().scan(cards: true);
    } on QrScanException {
      if (mounted) {
        showVayuNotice(
          context,
          'The camera could not be opened.',
          tone: VayuNoticeTone.problem,
        );
      }
      return;
    }
    if (text == null || !mounted) return;
    if (!text.trimLeft().toUpperCase().startsWith('BEGIN:VCARD')) {
      showVayuNotice(
        context,
        'That is a Receive code, not a card. Use Send to send files to that phone.',
      );
      return;
    }
    final stored = await store.addBytes(
      Uint8List.fromList(utf8.encode(text)),
      via: ReceivedVia.scan,
    );
    if (!mounted) return;
    showVayuNotice(
      context,
      stored == null ? 'That card could not be read.' : 'Saved ${stored.name}',
      tone: stored == null ? VayuNoticeTone.problem : VayuNoticeTone.success,
    );
  }

  Widget _card(ReceivedCard card) {
    final face = _faces[card.id];
    return Builder(
      builder: (cardContext) => GestureDetector(
        onLongPress: () => _ring(cardContext, card),
        child: face == null
            ? const AspectRatio(aspectRatio: 1.6)
            : VayuCardView(face: face),
      ),
    );
  }

  Widget _list(List<ReceivedCard> cards) {
    return LayoutBuilder(
      builder: (context, box) {
        final extent = (box.maxWidth - 2 * _side) / 1.6 + _gap;
        final scrolls = cards.length * extent + 2 * _ends > box.maxHeight;
        return ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(_side, _ends, _side, _ends),
          itemExtent: extent,
          itemCount: cards.length,
          itemBuilder: (context, i) {
            final tile = Padding(
              padding: const EdgeInsets.only(bottom: _gap),
              child: _card(cards[i]),
            );
            if (!scrolls) return tile;
            return AnimatedBuilder(
              animation: _scroll,
              child: tile,
              builder: (context, child) {
                // No dimensions on the first frame: treat as unscrolled.
                final position =
                    _scroll.hasClients &&
                        _scroll.position.hasContentDimensions &&
                        _scroll.position.hasPixels
                    ? _scroll.position
                    : null;
                final offset = position?.pixels ?? 0.0;
                final max = position?.maxScrollExtent ?? 0.0;
                final t = max > 0 ? (offset / max).clamp(0.0, 1.0) : 0.0;
                // The focus line moves from the first card's centre (top)
                // to the last card's centre (bottom) as the list scrolls.
                final focus =
                    offset +
                    _ends +
                    extent / 2 +
                    (box.maxHeight - 2 * _ends - extent) * t;
                final centre = _ends + i * extent + extent / 2;
                final distance = ((centre - focus).abs() / extent).clamp(
                  0.0,
                  1.0,
                );
                return Opacity(
                  opacity: 1 - 0.3 * distance,
                  child: Transform.scale(
                    scale: 1 - 0.1 * distance,
                    child: child,
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = _store;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Received cards'),
        actions: [
          IconButton(
            tooltip: 'Scan a card',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: _scanCard,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: store == null
          ? const SizedBox.shrink()
          : StreamBuilder<List<ReceivedCard>>(
              stream: store.changes,
              initialData: store.all,
              builder: (context, snapshot) {
                final cards = snapshot.data ?? const <ReceivedCard>[];
                _loadFaces(cards);
                if (cards.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.style_outlined,
                          size: 48,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No cards yet',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _scanCard,
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          label: const Text('Scan a card'),
                        ),
                      ],
                    ),
                  );
                }
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(_side, 8, _side, 0),
                      child: Text(
                        'Long-press a card to call, email, save or delete it.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(child: _list(cards)),
                  ],
                );
              },
            ),
    );
  }
}
