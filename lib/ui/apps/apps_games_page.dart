import 'package:flutter/material.dart';

import 'package:vayu/ui/widgets/coming_soon_view.dart';

/// Apps & games sharing is not built yet (owner deferred it); this page says
/// so instead of listing apps it cannot send.
class AppsGamesPage extends StatelessWidget {
  const AppsGamesPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AppsGamesPage()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Apps & games')),
      body: const SafeArea(
        child: ComingSoonView(
          icon: Icons.sports_esports_outlined,
          title: 'Apps & games are coming',
          summary:
              'Share installed apps and games with nearby phones. Paid apps '
              'and app data that Android protects will never be sent.',
        ),
      ),
    );
  }
}
