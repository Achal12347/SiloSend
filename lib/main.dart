import 'package:flutter/material.dart';

import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/ui/home/vayu_home_page.dart';

void main() {
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
  }

  @override
  void dispose() {
    if (widget.container == null) {
      _container.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      container: _container,
      child: MaterialApp(
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1E88E5), // Vayu blue
            brightness: Brightness.light,
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1E88E5),
            brightness: Brightness.dark,
          ),
        ),
        themeMode: ThemeMode.system,
        home: FutureBuilder<void>(
          future: _initFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Initializing device identity...'),
                    ],
                  ),
                ),
              );
            }
            if (snapshot.hasError) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 64,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Initialization Error',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Unable to initialize Vayu. Please try again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return const VayuHomePage();
          },
        ),
      ),
    );
  }
}
