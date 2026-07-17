import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/app/app_router.dart';
import 'package:silosend/app/theme.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      routerConfig: router,
      title: 'silosend',
      theme: AppTheme.material3Light(),
      darkTheme: AppTheme.material3Dark(),
      themeMode: ThemeMode.system,
    );
  }
}
