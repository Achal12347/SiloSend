import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/ui/transfer/transfer_history_page.dart';

void main() {
  late AppContainer container;

  setUp(() async {
    container = AppContainer.standard(
      storage: InMemoryIdentityStorage(
        LocalDeviceIdentity.generate(displayName: 'Local', platform: 'android'),
      ),
    );
    await container.initialize();
  });

  tearDown(() => container.dispose());

  TransferHistoryRecord record(
    String name, {
    bool outbound = false,
    TransferOutcome outcome = TransferOutcome.completed,
    String? kind,
  }) => TransferHistoryRecord(
    transferId: name,
    outbound: outbound,
    peerDeviceId: 'ab' * 16,
    peerName: 'Vayu-CalmOtter-4Q',
    fileName: name,
    sizeBytes: 2 * 1024 * 1024,
    mimeType: 'image/jpeg',
    outcome: outcome,
    failureKind: kind,
    finishedAt: DateTime.now(),
    savedPath: outbound ? null : '/nowhere/$name',
  );

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(home: TransferHistoryPage(container: container)),
  );

  testWidgets('empty history explains what will appear', (tester) async {
    await pump(tester);
    expect(
      find.text('Files you send and receive will be listed here.'),
      findsOneWidget,
    );
    expect(find.text('Clear'), findsNothing);
  });

  testWidgets('lists sent, received and failed transfers truthfully', (
    tester,
  ) async {
    final history = container.fileSharingCoordinator.history!;
    // The history lives in the real zone (created in setUp).
    await tester.runAsync(() async {
      await history.add(record('beach.jpg'));
      await history.add(record('report.pdf', outbound: true));
      await history.add(
        record(
          'video.mp4',
          outcome: TransferOutcome.failed,
          kind: TransferFailureKind.outOfSpace.name,
        ),
      );
    });
    await pump(tester);

    expect(find.text('beach.jpg'), findsOneWidget);
    expect(
      find.textContaining('From Vayu-CalmOtter-4Q · 2.0 MB'),
      findsOneWidget,
    );
    expect(
      find.textContaining('To Vayu-CalmOtter-4Q · 2.0 MB'),
      findsOneWidget,
    );
    expect(find.textContaining('Not enough storage space'), findsOneWidget);
  });

  testWidgets('removing an entry forgets it', (tester) async {
    await tester.runAsync(
      () => container.fileSharingCoordinator.history!.add(record('old.txt')),
    );
    await pump(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from history'));
    await tester.pumpAndSettle();
    // Let the real-zone save finish, then rebuild.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('old.txt'), findsNothing);
    expect(container.transferHistory, isEmpty);
  });

  testWidgets('Received shows only what arrived; Sent only what went out', (
    tester,
  ) async {
    final history = container.fileSharingCoordinator.history!;
    await tester.runAsync(() async {
      await history.add(record('beach.jpg'));
      await history.add(record('report.pdf', outbound: true));
      await history.add(record('broken.mp4', outcome: TransferOutcome.failed));
    });
    await pump(tester);
    expect(find.text('broken.mp4'), findsOneWidget);

    await tester.tap(find.text('Received'));
    await tester.pumpAndSettle();
    expect(find.text('beach.jpg'), findsOneWidget);
    expect(find.text('report.pdf'), findsNothing);
    expect(find.text('broken.mp4'), findsNothing);

    await tester.tap(find.text('Sent'));
    await tester.pumpAndSettle();
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('beach.jpg'), findsNothing);
  });

  testWidgets('Received with nothing yet says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TransferHistoryPage(
          container: container,
          initialFilter: HistoryFilter.received,
        ),
      ),
    );
    expect(find.text('Nothing received yet.'), findsOneWidget);
  });
}
