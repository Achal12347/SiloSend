import 'package:go_router/go_router.dart';
import 'package:silosend/features/about/presentation/about_screen.dart';
import 'package:silosend/features/chat/presentation/chat_screen.dart';
import 'package:silosend/features/discovery/presentation/discovery_screen.dart';
import 'package:silosend/features/history/presentation/history_screen.dart';
import 'package:silosend/features/home/presentation/home_screen.dart';
import 'package:silosend/features/settings/presentation/settings_screen.dart';
import 'package:silosend/features/transfer/presentation/transfer_screen.dart';

import 'constants.dart';

class AppRouter {
  static final GoRouter router = GoRouter(
    initialLocation: AppConstants.routeHome,
    routes: [
      GoRoute(
        path: AppConstants.routeHome,
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: AppConstants.routeDiscovery,
        builder: (context, state) => const DiscoveryScreen(),
      ),
      GoRoute(
        path: AppConstants.routeTransfer,
        builder: (context, state) => const TransferScreen(),
      ),
      GoRoute(
        path: AppConstants.routeSettings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: AppConstants.routeHistory,
        builder: (context, state) => const HistoryScreen(),
      ),
      GoRoute(
        path: AppConstants.routeChat,
        builder: (context, state) => const ChatScreen(),
      ),
      GoRoute(
        path: AppConstants.routeAbout,
        builder: (context, state) => const AboutScreen(),
      ),
    ],
  );
}
