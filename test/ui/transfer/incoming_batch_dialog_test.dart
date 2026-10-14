import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';
import 'package:vayu/ui/transfer/incoming_batch_dialog.dart';

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

  IncomingBatchRequest request({
    required int count,
    void Function()? onAccept,
    void Function(TransferCancelReason, String)? onReject,
  }) => IncomingBatchRequest(
    batchId: '0123456789abcdef0123456789abcdef',
    senderDeviceId: 'aabbccddeeff00112233445566778899',
    files: [
      for (var i = 0; i < count; i++)
        BatchManifestEntry(
          fileName: 'photo_$i.jpg',
          sizeBytes: 1024 * 1024,
          mimeType: 'image/jpeg',
        ),
    ],
    onAccept: () async => onAccept?.call(),
    onReject: (code, message) async => onReject?.call(code, message),
  );

  Future<void> pump(WidgetTester tester, IncomingBatchRequest r) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IncomingBatchDialog(request: r, container: container),
          ),
        ),
      );

  testWidgets('shows one decision for every file in the batch', (tester) async {
    await pump(tester, request(count: 3));
    expect(find.text('Incoming 3 files'), findsOneWidget);
    expect(find.text('3 files · 3.0 MB'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(find.text('photo_$i.jpg'), findsOneWidget);
    }
    expect(find.text('Accept all'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
  });

  testWidgets('long batches collapse until expanded', (tester) async {
    await pump(tester, request(count: 9));
    expect(find.text('photo_0.jpg'), findsOneWidget);
    expect(find.text('photo_8.jpg'), findsNothing);
    await tester.tap(find.text('Show 5 more'));
    await tester.pump();
    expect(find.text('photo_8.jpg'), findsOneWidget);
  });

  testWidgets('Decline refuses the whole batch', (tester) async {
    TransferCancelReason? code;
    await pump(tester, request(count: 2, onReject: (c, _) => code = c));
    await tester.tap(find.text('Decline'));
    await tester.pump();
    expect(code, TransferCancelReason.declined);
  });
}
