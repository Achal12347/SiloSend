import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/card/my_card_page.dart';
import 'package:vayu/ui/card/received_cards_page.dart';
import 'package:vayu/ui/home/share_actions.dart';
import 'package:vayu/ui/receive/receive_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

/// Exchanging profiles and contacts: everything card- and contact-related
/// in one place, kept apart from file transfers.
class ContactSharingPage extends StatelessWidget {
  final AppContainer container;

  const ContactSharingPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ContactSharingPage(container: container),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Contact sharing')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: palette.accentContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.swap_horiz_rounded,
                  size: 36,
                  color: palette.accent,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Exchange profiles and contacts',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Nothing is saved on the other phone until they choose to save it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Card(
              child: Column(
                children: [
                  _Row(
                    icon: Icons.badge_outlined,
                    title: 'Share my profile',
                    subtitle: 'Your card, by tap, code or to a nearby phone',
                    onTap: () => MyCardPage.open(context, container),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  _Row(
                    icon: Icons.person_add_alt_outlined,
                    title: 'Share a contact',
                    subtitle: 'Pick one from your phone, then the device',
                    onTap: () => ShareActions.shareContact(context, container),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  _Row(
                    icon: Icons.south_west_rounded,
                    title: 'Receive',
                    subtitle: 'Show your code so the other phone can send',
                    onTap: () => ReceivePage.open(context, container),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  _Row(
                    icon: Icons.contact_page_outlined,
                    title: 'Received cards',
                    subtitle: 'Cards others shared with you',
                    onTap: () => ReceivedCardsPage.open(context, container),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: theme.colorScheme.onSurface),
      ),
      title: Text(title, style: theme.textTheme.titleSmall),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}
