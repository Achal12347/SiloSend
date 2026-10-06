import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/lifecycle/app_lifecycle_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLifecycleManager Tests', () {
    late AppLifecycleManager manager;

    setUp(() {
      manager = AppLifecycleManager();
    });

    tearDown(() {
      manager.dispose();
    });

    test('initial state defaults to resumed and foreground', () {
      expect(manager.currentState, equals(AppLifecycleState.resumed));
      expect(manager.isForeground, isTrue);
      expect(manager.isBackground, isFalse);
    });

    test('transitions to background when paused', () async {
      final emittedStates = <AppLifecycleState>[];
      final subscription = manager.stateStream.listen(emittedStates.add);

      manager.transitionTo(AppLifecycleState.paused);

      expect(manager.currentState, equals(AppLifecycleState.paused));
      expect(manager.isForeground, isFalse);
      expect(manager.isBackground, isTrue);

      await pumpEventQueue();
      expect(emittedStates, contains(AppLifecycleState.paused));

      await subscription.cancel();
    });

    test('notifies registered listeners on transition', () {
      AppLifecycleState? observed;
      void listener(AppLifecycleState s) => observed = s;

      manager.addListener(listener);
      manager.transitionTo(AppLifecycleState.inactive);

      expect(observed, equals(AppLifecycleState.inactive));
      expect(manager.isForeground, isFalse);
      expect(manager.isBackground, isFalse);

      manager.removeListener(listener);
      manager.transitionTo(AppLifecycleState.resumed);
      // observed should remain inactive because listener was removed
      expect(observed, equals(AppLifecycleState.inactive));
    });

    test('ignores duplicate state transitions', () async {
      int notifications = 0;
      manager.addListener((_) => notifications++);

      manager.transitionTo(AppLifecycleState.resumed); // already resumed
      expect(notifications, equals(0));

      manager.transitionTo(AppLifecycleState.paused);
      expect(notifications, equals(1));

      manager.transitionTo(AppLifecycleState.paused); // duplicate
      expect(notifications, equals(1));
    });
  });
}
