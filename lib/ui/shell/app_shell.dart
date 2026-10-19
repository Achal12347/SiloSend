import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/domain/chat/chat_models.dart';

import 'package:vayu/ui/chats/chats_page.dart';
import 'package:vayu/ui/home/vayu_home_page.dart';
import 'package:vayu/ui/host/host_client_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

/// The three main destinations with a bottom navigation bar.
///
/// Every tab stays alive (an [IndexedStack]): Home keeps listening for
/// incoming files and shared items while another tab is open, and each tab
/// keeps its scroll position. Back on another tab returns to Home first.
class AppShell extends StatefulWidget {
  /// Tab shown first (tests).
  final int initialIndex;

  const AppShell({super.key, this.initialIndex = 0});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _index = widget.initialIndex;

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home_rounded),
      label: 'Home',
    ),
    NavigationDestination(
      icon: Icon(Icons.chat_bubble_outline_rounded),
      selectedIcon: Icon(Icons.chat_bubble_rounded),
      label: 'Chats',
    ),
    NavigationDestination(
      icon: Icon(Icons.hub_outlined),
      selectedIcon: Icon(Icons.hub_rounded),
      label: 'Host & Client',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != 0) setState(() => _index = 0);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: const [VayuHomePage(), ChatsPage(), HostClientPage()],
        ),
        bottomNavigationBar: _ChatAwareNavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: _destinations,
        ),
      ),
    );
  }
}

/// The bottom bar, with the number of unread messages and message requests
/// on Chats.
class _ChatAwareNavigationBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  const _ChatAwareNavigationBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  @override
  Widget build(BuildContext context) {
    final chat = AppScope.of(context).chatService;
    return StreamBuilder<List<Conversation>>(
      stream: chat.changes,
      builder: (context, _) {
        final count = chat.unreadChats + chat.requests.length;
        // Sage, not Material's bright error red (Vayu palette).
        final palette = VayuPalette.of(context);
        return NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: [
            for (var i = 0; i < destinations.length; i++)
              if (i == 1 && count > 0)
                NavigationDestination(
                  icon: Badge.count(
                    count: count,
                    backgroundColor: palette.accent,
                    child: destinations[i].icon,
                  ),
                  selectedIcon: Badge.count(
                    count: count,
                    backgroundColor: palette.accent,
                    child: destinations[i].selectedIcon ?? destinations[i].icon,
                  ),
                  label: destinations[i].label,
                )
              else
                destinations[i],
          ],
        );
      },
    );
  }
}
