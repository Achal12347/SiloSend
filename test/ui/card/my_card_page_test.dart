import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/card/my_card_page.dart';

void main() {
  late AppContainer container;

  setUp(() async {
    container = AppContainer.standard(
      storage: InMemoryIdentityStorage(
        LocalDeviceIdentity.generate(displayName: 'Phone', platform: 'android'),
      ),
      settingsStorage: InMemorySettingsStorage(
        const UserSettings(onboardingVersion: 1, profileName: 'Riya Sharma'),
      ),
    );
    await container.initialize();
  });

  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: MyCardPage(container: container)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('without a card it offers to create one', (tester) async {
    await pump(tester);
    expect(find.text('Create your card'), findsOneWidget);
  });

  testWidgets('creating a card prefills the name and saves it', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Create your card'));
    await tester.pumpAndSettle();

    // Name comes from onboarding; the preview shows it live.
    expect(find.widgetWithText(TextFormField, 'Riya Sharma'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Job title'),
      'Designer',
    );
    await tester.pump();
    expect(find.text('Designer'), findsWidgets);

    await tester.runAsync(() async {
      await tester.tap(find.text('Save card'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(container.myCard?.name, 'Riya Sharma');
    expect(container.myCard?.title, 'Designer');
    expect(find.text('Show QR code'), findsOneWidget);
    expect(find.text('Send to a nearby phone'), findsOneWidget);
  });

  testWidgets('an existing card shows its share options and QR', (
    tester,
  ) async {
    await tester.runAsync(
      () => container.saveMyCard(
        const VayuCard(name: 'Riya Sharma', phone: '+91 98765 43210'),
      ),
    );
    await pump(tester);
    expect(find.text('Riya Sharma'), findsOneWidget);
    // No NFC adapter in tests: the screen says so instead of pretending.
    expect(find.text('No tap on this phone'), findsOneWidget);

    await tester.tap(find.text('Show QR code'));
    await tester.pumpAndSettle();
    expect(find.text('Scan to save'), findsOneWidget);
    expect(find.bySemanticsLabel('QR code with your card'), findsOneWidget);
  });
}
