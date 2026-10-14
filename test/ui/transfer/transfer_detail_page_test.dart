import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/transfer/payload_source.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';

import '../../core/transfer/transfer_task_test.dart' show TestSecureSession;

const _id = 'abababababababababababababababab';

TransferAckPayload _ack(TransferAckType type, int highest, int bytes) =>
    TransferAckPayload.cumulative(
      transferId: parseIdTo16Bytes(_id),
      ackType: type,
      highestContiguousChunkIndex: highest,
      bytesReceived: bytes,
    );

void main() {
  late AppContainer container;

  setUp(() async {
    container = AppContainer.standard(
      storage: InMemoryIdentityStorage(
        LocalDeviceIdentity.generate(displayName: 'Me', platform: 'android'),
      ),
    );
    await container.initialize();
  });

  tearDown(() => container.dispose());

  Future<OutboundTransferTask> startTask({int chunks = 2}) async {
    final data = Uint8List(64 * 1024 * chunks);
    final source = MemoryPayloadSource(data);
    final task = OutboundTransferTask(
      transferId: _id,
      localDeviceId: '11111111111111111111111111111111',
      remoteDeviceId: '22222222222222222222222222222222',
      secureSession: TestSecureSession(),
      source: source,
      metadata: TransferMetadata(
        transferId: _id,
        fileName: 'holiday.mp4',
        totalBytes: data.length,
        chunkSize: 64 * 1024,
        sha256Checksum: await source.computeSha256(),
      ),
      verificationTimeout: const Duration(milliseconds: 200),
    );
    await task.start();
    return task;
  }

  Future<void> pumpPage(WidgetTester tester, OutboundTransferTask task) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: VayuTheme.light(),
        home: TransferDetailPage(container: container, task: task),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'shows waiting, live progress, verification, then verified success',
    (tester) async {
      final task = await tester.runAsync(startTask);
      await pumpPage(tester, task!);

      expect(find.text('Sending'), findsOneWidget);
      expect(find.text('Waiting for nearby device to accept'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      await tester.runAsync(() async {
        task.handleAck(
          _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked, 0),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        task.handleAck(_ack(TransferAckType.chunkReceived, 0, 64 * 1024));
      });
      await tester.pump();
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('Sending securely'), findsOneWidget);

      await tester.runAsync(() async {
        task.handleAck(_ack(TransferAckType.chunkReceived, 1, 128 * 1024));
      });
      await tester.pump();
      // Every byte is acknowledged but the receiver has not confirmed its hash yet.
      expect(find.text('Verifying'), findsWidgets);
      expect(find.text('Transfer complete'), findsNothing);

      await tester.runAsync(() async {
        task.handleAck(_ack(TransferAckType.transferCompleted, 1, 128 * 1024));
        await task.done;
      });
      await tester.pump();
      expect(find.text('Transfer complete'), findsOneWidget);
      expect(
        find.text('Delivered and verified by nearby device'),
        findsOneWidget,
      );
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
    },
  );

  testWidgets(
    'a missing receiver confirmation is shown as a failure, not success',
    (tester) async {
      final task = await tester.runAsync(() => startTask(chunks: 1));
      await pumpPage(tester, task!);

      await tester.runAsync(() async {
        task.handleAck(
          _ack(TransferAckType.offerAccepted, TransferAckPayload.noneAcked, 0),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        task.handleAck(_ack(TransferAckType.chunkReceived, 0, 64 * 1024));
        await task.done.catchError((_) {});
      });
      await tester.pump();

      expect(find.text('Transfer failed'), findsOneWidget);
      expect(
        find.text(
          'All data was sent, but the other device never confirmed the file.',
        ),
        findsOneWidget,
      );
      expect(find.text('Transfer complete'), findsNothing);
    },
  );
}
