import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/card/my_card_page.dart';
import 'package:vayu/ui/card/received_cards_page.dart';
import 'package:vayu/ui/home/share_actions.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Card(
              child: Column(
                children: [
                  _Row(
                    icon: Icons.badge_outlined,
                    title: 'Share my profile',
                    onTap: () => MyCardPage.open(context, container),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  _Row(
                    icon: Icons.person_add_alt_outlined,
                    title: 'Share a contact',
                    onTap: () => ShareActions.shareContact(context, container),
                  ),
                  const Divider(indent: 72, endIndent: 16),
                  _Row(
                    icon: Icons.contact_page_outlined,
                    title: 'Received cards',
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
  final VoidCallback onTap;

  const _Row({required this.icon, required this.title, required this.onTap});

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
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}
