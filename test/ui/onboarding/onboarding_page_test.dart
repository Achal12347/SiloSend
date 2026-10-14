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

  Future<void> next(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  // Saving runs against the real container, outside the fake clock.
  Future<void> finish(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Not now'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('first launch shows onboarding, not home', (tester) async {
    await tester.pumpWidget(VayuApp(container: container));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Vayu'), findsOneWidget);
    expect(find.text('Nearby devices'), findsNothing);
  });

  testWidgets('name step suggests a phone name and saves both', (tester) async {
    await tester.pumpWidget(VayuApp(container: container));
    await tester.pumpAndSettle();
    await next(tester, 'Get started');

    expect(find.text('What should we call you?'), findsOneWidget);
    // The phone name starts as the current device name.
    expect(find.text('Vayu-CalmOtter-4Q'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Your name'),
      'Riya Sharma',
    );
    await tester.pump();
    expect(find.text("Riya's phone"), findsOneWidget);

    await next(tester, 'Continue'); // privacy
    await next(tester, 'Continue'); // nearby access
    expect(find.text('Find phones nearby'), findsOneWidget);
    await finish(tester);

    expect(container.userSettings.profileName, 'Riya Sharma');
    expect(container.identity?.displayName, "Riya's phone");
    expect(container.userSettings.needsOnboarding, isFalse);
    expect(find.text('Welcome to Vayu'), findsNothing);
  });

  testWidgets('skip goes to the last step and keeps the device name', (
    tester,
  ) async {
    await tester.pumpWidget(VayuApp(container: container));
    await tester.pumpAndSettle();
    await next(tester, 'Skip');
    expect(find.text('Find phones nearby'), findsOneWidget);
    await finish(tester);

    expect(container.identity?.displayName, 'Vayu-CalmOtter-4Q');
    expect(container.userSettings.profileName, isNull);
    expect(container.userSettings.needsOnboarding, isFalse);
  });

  test('settings remember onboarding and the name across restarts', () {
    const done = UserSettings(onboardingVersion: 1, profileName: 'Riya');
    final back = UserSettings.fromJson(done.toJson());
    expect(back.needsOnboarding, isFalse);
    expect(back.profileName, 'Riya');
    expect(UserSettings.fromJson(const {}).needsOnboarding, isTrue);
  });
}
