import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/domain/chat/chat_models.dart';

import 'package:vayu/ui/chats/chats_page.dart';
import 'package:vayu/ui/home/vayu_home_page.dart';
import 'package:vayu/ui/host/host_client_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/readable_width.dart';

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
      child: Builder(
        builder: (context) {
          final pages = IndexedStack(
            index: _index,
            children: const [VayuHomePage(), ChatsPage(), HostClientPage()],
          );
          void select(int i) => setState(() => _index = i);
          // Tablets, landscape and wide windows: navigation at the side.
          if (isWideLayout(context)) {
            return Scaffold(
              body: Row(
                children: [
                  _ChatAwareNavigation(
                    rail: true,
                    selectedIndex: _index,
                    onDestinationSelected: select,
                    destinations: _destinations,
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: pages),
                ],
              ),
            );
          }
          return Scaffold(
            body: pages,
            bottomNavigationBar: _ChatAwareNavigation(
              rail: false,
              selectedIndex: _index,
              onDestinationSelected: select,
              destinations: _destinations,
            ),
          );
        },
      ),
    );
  }
}

/// The bottom bar (or side rail on wide screens), with the number of unread
/// messages and message requests on Chats.
class _ChatAwareNavigation extends StatelessWidget {
  final bool rail;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  const _ChatAwareNavigation({
    required this.rail,
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
        Widget badged(int i, Widget icon) => i == 1 && count > 0
            ? Badge.count(
                count: count,
                backgroundColor: palette.accent,
                child: icon,
              )
            : icon;
        if (rail) {
          return NavigationRail(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (var i = 0; i < destinations.length; i++)
                NavigationRailDestination(
                  icon: badged(i, destinations[i].icon),
                  selectedIcon: badged(
                    i,
                    destinations[i].selectedIcon ?? destinations[i].icon,
                  ),
                  label: Text(destinations[i].label),
                ),
            ],
          );
        }
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
