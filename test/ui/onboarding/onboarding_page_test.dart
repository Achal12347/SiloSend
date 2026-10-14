import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/main.dart';

void main() {
  late AppContainer container;

  setUp(() async {
    container = AppContainer.standard(
      storage: InMemoryIdentityStorage(
        LocalDeviceIdentity.generate(
          displayName: 'Vayu-CalmOtter-4Q',
          platform: 'android',
        ),
      ),
      settingsStorage: InMemorySettingsStorage(),
    );
    await container.initialize();
  });

  tearDown(() => container.dispose());

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  // Saving runs against the real container, outside the fake clock.
  Future<void> tapAndSave(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('first launch shows three slides that can be swiped', (
    tester,
  ) async {
    await tester.pumpWidget(VayuApp(container: container));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Vayu'), findsOneWidget);
    expect(find.bySemanticsLabel('Step 1 of 3'), findsOneWidget);

    await tester.fling(
      find.text('Welcome to Vayu'),
      const Offset(-400, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.text('Private by design'), findsOneWidget);
  });

  testWidgets('profile step saves the name, card and phone name', (
    tester,
  ) async {
    await tester.pumpWidget(VayuApp(container: container));
    await tester.pumpAndSettle();
    await tap(tester, 'Get started');
    await tap(tester, 'Continue');
    expect(find.text('Set up your profile'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Riya Sharma');
    await tester.pump();
    expect(
      find.text('Nearby phones will see "Riya\'s phone".'),
      findsOneWidget,
    );
    await tapAndSave(tester, 'Continue');

    expect(container.userSettings.profileName, 'Riya Sharma');
    expect(container.myCard?.name, 'Riya Sharma');
    expect(container.identity?.displayName, "Riya's phone");
    expect(container.userSettings.needsOnboarding, isFalse);
    expect(
      find.text('Set up your profile so friends know it\'s you'),
      findsNothing,
    );
  });

  testWidgets('skipping shows the profile banner on home, which can close', (
    tester,
  ) async {
    await tester.pumpWidget(VayuApp(container: container));
    await tester.pumpAndSettle();
    await tap(tester, 'Skip');
    await tapAndSave(tester, 'Skip for now');

    expect(container.userSettings.needsOnboarding, isFalse);
    expect(container.identity?.displayName, 'Vayu-CalmOtter-4Q');
    final banner = find.text('Set up your profile so friends know it\'s you');
    expect(banner, findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Not now'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(container.userSettings.profilePromptDismissed, isTrue);
    // Home starts searching on its own; stop it before the test ends.
    container.discoveryCoordinator.stopAdvertising();
    container.discoveryCoordinator.stopDiscovery();
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a name the user typed for the phone is never replaced', (
    tester,
  ) async {
    await tester.runAsync(
      () => container.updateCustomDisplayName('Kitchen tablet'),
    );
    await tester.runAsync(() => container.setUpProfile('Riya'));
    expect(container.identity?.displayName, 'Kitchen tablet');
    expect(container.myCard?.name, 'Riya');
  });

  test('settings remember onboarding, name and banner across restarts', () {
    const done = UserSettings(
      onboardingVersion: 1,
      profileName: 'Riya',
      profilePromptDismissed: true,
    );
    final back = UserSettings.fromJson(done.toJson());
    expect(back.needsOnboarding, isFalse);
    expect(back.profileName, 'Riya');
    expect(back.profilePromptDismissed, isTrue);
    expect(UserSettings.fromJson(const {}).needsOnboarding, isTrue);
  });
}
