import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:vayu/core/logging/app_logger.dart';

/// Manages application lifecycle transitions (foreground, inactive, background).
///
/// Ensures wireless operations, discovery beacons, and socket workers can react
/// appropriately when the app is backgrounded or resumed.
class AppLifecycleManager with WidgetsBindingObserver {
  AppLifecycleState _state = AppLifecycleState.resumed;
  final StreamController<AppLifecycleState> _stateController =
      StreamController<AppLifecycleState>.broadcast();
  final List<void Function(AppLifecycleState)> _listeners = [];
  bool _isObserving = false;

  AppLifecycleManager();

  /// Current application lifecycle state.
  AppLifecycleState get currentState => _state;

  /// Reactive stream of lifecycle state transitions.
  Stream<AppLifecycleState> get stateStream => _stateController.stream;

  /// Whether the app is currently in the active foreground.
  bool get isForeground => _state == AppLifecycleState.resumed;

  /// Whether the app is currently in the background.
  bool get isBackground => _state == AppLifecycleState.paused;

  /// Starts observing platform lifecycle events via [WidgetsBinding].
  void start() {
    if (_isObserving) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _isObserving = true;
      AppLogger.info('AppLifecycleManager', 'Started lifecycle observation');
    } catch (e) {
      // In headless unit tests where WidgetsBinding is uninitialized, handle gracefully
      AppLogger.warning(
        'AppLifecycleManager',
        'WidgetsBinding not ready to observe lifecycle',
        error: e,
      );
    }
  }

  /// Stops observing platform lifecycle events.
  void stop() {
    if (!_isObserving) return;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _isObserving = false;
    AppLogger.info('AppLifecycleManager', 'Stopped lifecycle observation');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _transitionTo(state);
  }

  /// Directly updates the lifecycle state.
  ///
  /// Useful for programmatic transitions and unit tests.
  void transitionTo(AppLifecycleState state) {
    _transitionTo(state);
  }

  void _transitionTo(AppLifecycleState state) {
    if (_state == state) return;
    _state = state;
    AppLogger.info(
      'AppLifecycleManager',
      'App lifecycle transitioned to: $state',
    );
    _stateController.add(state);
    for (final listener in List.of(_listeners)) {
      try {
        listener(state);
      } catch (e, stack) {
        AppLogger.error(
          'AppLifecycleManager',
          'Error in lifecycle listener',
          error: e,
          stackTrace: stack,
        );
      }
    }
  }

  /// Subscribes a synchronous callback listener for lifecycle transitions.
  void addListener(void Function(AppLifecycleState) listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// Unsubscribes a synchronous callback listener.
  void removeListener(void Function(AppLifecycleState) listener) {
    _listeners.remove(listener);
  }

  /// Disposes resources and terminates active streams.
  void dispose() {
    stop();
    _listeners.clear();
    _stateController.close();
  }
}
