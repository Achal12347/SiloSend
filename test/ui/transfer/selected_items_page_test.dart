import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/selected_items_page.dart';

void main() {
  late AppContainer container;

  Future<void> open(WidgetTester tester, {String? folder}) async {
    await tester.runAsync(() async {
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(
          LocalDeviceIdentity(
            deviceId: Uint8List.fromList(List.filled(16, 4)),
            displayName: 'Tester',
            platform: 'android',
            createdAt: DateTime.now(),
          ),
        ),
      );
      await container.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => SelectedItemsPage.open(
                context,
                container: container,
                folderName: folder,
                documents: const [
                  SelectedDocument(
                    identifier: 'content://a',
                    name: 'trip.mp4',
                    sizeBytes: 2000000,
                    mimeType: 'video/mp4',
                  ),
                  SelectedDocument(
                    identifier: 'content://b',
                    name: 'notes.pdf',
                    sizeBytes: 500000,
                    mimeType: 'application/pdf',
                  ),
                ],
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
  }

  tearDown(() async {
    await container.stopDiscoveryAndAdvertising();
    container.dispose();
  });

  testWidgets('shows what was picked, how many and how big', (tester) async {
    await open(tester);
    expect(find.text('Selected files'), findsOneWidget);
    expect(find.text('2 items selected'), findsOneWidget);
    expect(find.text(formatBytes(2500000)), findsOneWidget);
    expect(find.text('trip.mp4'), findsOneWidget);
    expect(find.text('notes.pdf'), findsOneWidget);
  });

  testWidgets('an item can be removed; removing all goes back', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Remove trip.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('trip.mp4'), findsNothing);
    expect(find.text('1 item selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove notes.pdf'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectedItemsPage), findsNothing);
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('a folder shows its name', (tester) async {
    await open(tester, folder: 'Holiday');
    expect(find.text('Send a folder'), findsOneWidget);
    expect(find.text('Holiday · 2 files'), findsOneWidget);
  });

  testWidgets('Next opens the device screen with Scan QR', (tester) async {
    await open(tester);
    await tester.tap(find.text('Next: choose device'));
    await tester.pumpAndSettle();
    expect(find.text('Select device'), findsOneWidget);
    expect(find.text('Scan QR'), findsOneWidget);
    // Back returns to the review, selection intact.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('2 items selected'), findsOneWidget);
    container.endDiscoveryWindow();
  });
}
