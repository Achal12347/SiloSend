import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/app/router.dart';
import 'package:silosend/core/theme/app_theme.dart';
import 'package:silosend/services/permissions/nearby_device_permission_service.dart';

class App extends ConsumerStatefulWidget {
  final bool enableNearbyPermissionPrompt;

  const App({super.key, this.enableNearbyPermissionPrompt = true});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      title: 'silosend',
      theme: AppTheme.material3Light(),
      darkTheme: AppTheme.material3Dark(),
      themeMode: ThemeMode.system,
      builder: (context, child) {
        return _NearbyPermissionPromptGate(
          enabled: widget.enableNearbyPermissionPrompt,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

class _NearbyPermissionPromptGate extends StatefulWidget {
  final bool enabled;
  final Widget child;

  const _NearbyPermissionPromptGate({
    required this.enabled,
    required this.child,
  });

  @override
  State<_NearbyPermissionPromptGate> createState() =>
      _NearbyPermissionPromptGateState();
}

class _NearbyPermissionPromptGateState
    extends State<_NearbyPermissionPromptGate> {
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptNearbyPermissionsIfNeeded();
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }

  Future<void> _promptNearbyPermissionsIfNeeded() async {
    if (_prompted || !widget.enabled || !mounted) return;
    _prompted = true;

    final shouldContinue = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Allow nearby device access?'),
          content: const Text(
            'SiloSend needs Bluetooth and nearby Wi-Fi permissions to discover devices and connect.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );

    if (shouldContinue != true || !mounted) {
      return;
    }

    try {
      await NearbyDevicePermissionService().requestNearbyPermissions();
    } catch (_) {
      // Discovery and connection flows will still handle the failure path.
    }
  }
}
