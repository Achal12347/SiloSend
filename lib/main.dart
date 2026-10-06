import 'package:flutter/material.dart';

import 'package:silosend_datasharing_app/core/constants/app_constants.dart';
import 'package:silosend_datasharing_app/core/state/app_container.dart';
import 'package:silosend_datasharing_app/core/state/app_scope.dart';
import 'package:silosend_datasharing_app/ui/home/silosend_home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SiloSendApp());
}

/// Root widget for the SiloSend application.
class SiloSendApp extends StatefulWidget {
  final AppContainer? container;

  const SiloSendApp({super.key, this.container});

  @override
  State<SiloSendApp> createState() => _SiloSendAppState();
}

class _SiloSendAppState extends State<SiloSendApp> {
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
            seedColor: const Color(0xFF1E88E5), // SiloSend blue
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
                          'Unable to initialize SiloSend. Please try again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return const SiloSendHomePage();
          },
        ),
      ),
    );
  }
}
