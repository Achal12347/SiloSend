import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:silosend/app/constants.dart';
import 'package:silosend/models/device.dart';
import 'package:silosend/features/about/presentation/about_screen.dart';
import 'package:silosend/features/chat/presentation/chat_screen.dart';
import 'package:silosend/features/discovery/presentation/discovery_screen.dart';
import 'package:silosend/features/connection/presentation/connection_screen.dart';
import 'package:silosend/features/history/presentation/history_screen.dart';
import 'package:silosend/features/home/presentation/home_screen.dart';
import 'package:silosend/features/settings/presentation/settings_screen.dart';
import 'package:silosend/features/transfer/presentation/transfer_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
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
        path: AppConstants.routeConnection,
        builder: (context, state) {
          final device = state.extra as Device?;
          return ConnectionScreen(
            device:
                device ??
                const Device(
                  id: '',
                  name: 'Unknown Device',
                  distanceLabel: 'Nearby',
                ),
          );
        },
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
        path: AppConstants.routeSettings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: AppConstants.routeAbout,
        builder: (context, state) => const AboutScreen(),
      ),
    ],
  );
});
