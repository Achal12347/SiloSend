import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vayu/ui/card/incoming_card_watcher.dart';

import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/constants/app_paths.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/ui/app_error_handling.dart';
import 'package:vayu/ui/shell/app_shell.dart';
import 'package:vayu/ui/onboarding/onboarding_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_mark.dart';

void main(List<String> args) {
  AppPaths.configureFromArgs(args);
  WidgetsFlutterBinding.ensureInitialized();
  installErrorHandlers();
  runApp(const VayuApp());
}

/// Root widget for the Vayu application.
class VayuApp extends StatefulWidget {
  final AppContainer? container;

  const VayuApp({super.key, this.container});

  @override
  State<VayuApp> createState() => _VayuAppState();
}

class _VayuAppState extends State<VayuApp> {
  late final AppContainer _container;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _container = widget.container ?? AppContainer.standard();
    _initFuture = _container.isInitialized
        ? Future.value()
        : _container.initialize();
    // Saved settings (including the theme) are only known after initialize.
    _initFuture.then((_) {
      if (mounted) setState(() {});
    }, onError: (_) {});
  }

  @override
  void dispose() {
    if (widget.container == null) {
      _container.dispose();
    }
    super.dispose();
  }

  ThemeMode _themeModeFor(UserSettings settings) {
    switch (settings.themePreference) {
      case AppThemePreference.light:
        return ThemeMode.light;
      case AppThemePreference.dark:
        return ThemeMode.dark;
      case AppThemePreference.system:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      container: _container,
      child: StreamBuilder<UserSettings>(
        stream: _container.userSettingsStream,
        initialData: _container.userSettings,
        builder: (context, settingsSnapshot) {
          final settings = settingsSnapshot.data ?? _container.userSettings;
          return MaterialApp(
            title: AppConstants.appName,
            debugShowCheckedModeBanner: false,
            scaffoldMessengerKey: rootMessengerKey,
            navigatorKey: rootNavigatorKey,
            // Cards tapped from another phone open here, on any screen.
            builder: (context, child) => IncomingCardWatcher(
              container: _container,
              ready: _initFuture,
              child: child!,
            ),
            theme: VayuTheme.light(),
            darkTheme: VayuTheme.dark(),
            themeMode: _themeModeFor(settings),
            home: FutureBuilder<void>(
              future: _initFuture,
              builder: (context, snapshot) {
                final Widget page;
                if (snapshot.connectionState == ConnectionState.waiting) {
                  page = const _StartupScreen();
                } else if (snapshot.hasError) {
                  page = const _StartupErrorScreen();
                } else if (settings.needsOnboarding) {
                  page = OnboardingPage(container: _container);
                } else {
                  page = const AppShell();
                }
                // Each stage fades into the next instead of jumping.
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  child: KeyedSubtree(
                    key: ValueKey(page.runtimeType),
                    child: page,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Matches the native splash (same background and mark), so start-up looks
/// like one continuous screen. A spinner appears only if start-up is slow.
class _StartupScreen extends StatefulWidget {
  const _StartupScreen();

  @override
  State<_StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<_StartupScreen> {
  Timer? _slowTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _slowTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const VayuMark(size: 96),
            const SizedBox(height: 32),
            SizedBox(
              width: 22,
              height: 22,
              child: _slow
                  ? const CircularProgressIndicator(strokeWidth: 2.4)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 56,
                color: palette.danger,
              ),
              const SizedBox(height: 16),
              Text('Vayu could not start', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Close the app and open it again. If this keeps happening, '
                'reinstalling Vayu resets its local data.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
