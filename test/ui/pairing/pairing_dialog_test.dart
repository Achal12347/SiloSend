import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silosend_datasharing_app/core/identity/identity_storage.dart';
import 'package:silosend_datasharing_app/core/state/app_container.dart';
import 'package:silosend_datasharing_app/domain/identity/local_device_identity.dart';
import 'package:silosend_datasharing_app/platform/system_platform_service.dart';
import 'package:silosend_datasharing_app/ui/pairing/pairing_dialog.dart';

void main() {
  group('PairingDialog Widget Tests', () {
    late LocalDeviceIdentity identity;
    late AppContainer container;

    setUp(() async {
      identity = LocalDeviceIdentity.generate(
        displayName: 'My-Pixel-Device',
        platform: 'android',
      );
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(identity),
        platformService: SystemPlatformService(platformNameOverride: 'android'),
      );
      await container.initialize();
    });

    tearDown(() {
      container.dispose();
    });

    testWidgets('renders local pairing URI and device details', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => PairingDialog.show(context, container),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open dialog
      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('Out-of-Band Pairing'), findsOneWidget);
      expect(find.text('Local Pairing URI'), findsOneWidget);
      expect(find.text('My-Pixel-Device'), findsOneWidget);
      expect(find.text('Connect Out-of-Band'), findsOneWidget);

      // Verify NFC capability status (unprobed/unsupported on desktop test environment)
      expect(
        find.textContaining('NFC Unsupported on this Device'),
        findsOneWidget,
      );

      // Close dialog
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Out-of-Band Pairing'), findsNothing);
    });

    testWidgets('shows validation error on invalid manual connection input', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => PairingDialog.show(context, container),
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      // Enter invalid input
      await tester.enterText(
        find.byType(TextField),
        'invalid_non_uri_string_without_colon',
      );
      await tester.ensureVisible(find.text('Connect Out-of-Band'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect Out-of-Band'));
      await tester.pumpAndSettle();

      // Error message should appear
      expect(
        find.textContaining(
          'Please enter a valid silosend://pair URI or IP:Port',
        ),
        findsOneWidget,
      );
    });
  });
}
