import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/receive/receive_page.dart';

void main() {
  late AppContainer container;

  setUp(() async {
    container = AppContainer.standard(
      storage: InMemoryIdentityStorage(
        LocalDeviceIdentity.generate(
          displayName: "Riya's phone",
          platform: 'android',
        ),
      ),
      settingsStorage: InMemorySettingsStorage(
        const UserSettings(onboardingVersion: 1),
      ),
    );
    await container.initialize();
  });

  tearDown(() => container.dispose());

  testWidgets('shows the phone as visible and opens a receive session', (
    tester,
  ) async {
    // Discovery touches Android-only channels that do not exist on the test
    // host; those "missing plugin" reports are not what this test checks.
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is MissingPluginException) return;
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: ReceivePage(container: container)),
      );
      // Let the code be prepared against the real container.
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump();

    expect(find.text("Receiving as Riya's phone"), findsOneWidget);
    // Either a code is shown (and files with its ticket are accepted), or
    // the screen explains how to get one; never a silent blank.
    final hasCode = find
        .bySemanticsLabel('Code to send files to this phone')
        .evaluate()
        .isNotEmpty;
    expect(container.fileSharingCoordinator.isReceiving, hasCode);
    if (hasCode) {
      expect(find.textContaining('Ready for'), findsOneWidget);
    } else {
      expect(find.text('Start again'), findsOneWidget);
    }
    // The receiver only shows its code; scanning belongs to the sender.
    expect(find.text('Other ways to connect'), findsNothing);

    // Leaving the screen ends the session.
    await tester.pumpWidget(const SizedBox());
    expect(container.fileSharingCoordinator.isReceiving, isFalse);
    await tester.runAsync(() async {
      await container.discoveryCoordinator.stopAdvertising();
      await container.discoveryCoordinator.stopDiscovery();
    });
  });
}
