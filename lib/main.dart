import 'package:flutter/material.dart';

import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/constants/app_paths.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/ui/home/vayu_home_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

void main(List<String> args) {
  AppPaths.configureFromArgs(args);
  WidgetsFlutterBinding.ensureInitialized();
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
            theme: VayuTheme.light(),
            darkTheme: VayuTheme.dark(),
            themeMode: _themeModeFor(settings),
            home: FutureBuilder<void>(
              future: _initFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const _StartupScreen();
                }
                if (snapshot.hasError) {
                  return const _StartupErrorScreen();
                }
                return const VayuHomePage();
              },
            ),
          );
        },
      ),
    );
  }
}

class _StartupScreen extends StatelessWidget {
  const _StartupScreen();

  @override
  Widget build(BuildContext context) {
    final palette = VayuPalette.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: palette.heroGradient,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(Icons.air_rounded, color: palette.heroGlow, size: 40),
            ),
            const SizedBox(height: 20),
            Text(AppConstants.appName, style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text('by Achyrio', style: theme.textTheme.bodySmall),
            const SizedBox(height: 28),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
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
