import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/ui/transfer/transfer_progress_card.dart';

void main() {
  group('TransferProgressCard Widget Tests', () {
    late LocalDeviceIdentity localIdentity;
    late AppContainer container;

    setUp(() async {
      localIdentity = LocalDeviceIdentity.generate(
        displayName: 'Local-Device',
        platform: 'android',
      );
      container = AppContainer.standard(
        storage: InMemoryIdentityStorage(localIdentity),
      );
      await container.initialize();
    });

    tearDown(() {
      container.dispose();
    });

    testWidgets('renders SizedBox.shrink when there are no active transfers', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TransferProgressCard(container: container)),
        ),
      );

      expect(find.text('Transfers'), findsNothing);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('renders active transfer card with fileName, speed, and ETA', (
      tester,
    ) async {
      final progressController = StreamController<TransferProgress>.broadcast();

      final metadata = TransferMetadata(
        transferId: 'task1234567890123456789012345678',
        fileName: 'recorded_video.mp4',
        totalBytes: 10 * 1024 * 1024, // 10 MB
        chunkSize: 64 * 1024,
        sha256Checksum:
            '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff',
        mimeType: 'video/mp4',
      );

      final dummyTask = _MockTransferTask(
        metadata: metadata,
        progressStream: progressController.stream,
      );

      // Add task to coordinator
      container.fileSharingCoordinator.activeTransfersStream; // trigger stream
      // We can test by injecting task through custom coordinator tracking or testing widget with mock
      // Since container.activeTransfersStream reads from container.fileSharingCoordinator,
      // let's verify TransferProgressCard displays the task correctly
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferProgressCard(
              container: container,
              initialTransfers: [dummyTask],
            ),
          ),
        ),
      );

      // Emit active progress
      progressController.add(
        TransferProgress(
          transferId: metadata.transferId,
          totalBytes: metadata.totalBytes,
          bytesTransferred: 5 * 1024 * 1024,
          currentChunkIndex: 80,
          speedBytesPerSecond: 1024 * 1024, // 1 MB/s
          etaSeconds: 5,
        ),
      );
      await tester.pump();

      expect(find.text('recorded_video.mp4'), findsOneWidget);
      expect(find.text('1 active'), findsOneWidget);
      expect(find.text('Transfers'), findsOneWidget);
      // Real engine numbers: 50%, 1 MB/s, 5 seconds remaining
      expect(find.text('50% · 1.0 MB/s · 5s left'), findsOneWidget);
      expect(find.byTooltip('Cancel transfer'), findsOneWidget);

      await progressController.close();
    });

    testWidgets(
      'renders completed transfer with Verified successfully, Share again, and Done (UI7 & UI8)',
      (tester) async {
        final metadata = TransferMetadata(
          transferId: 'completed_task_1',
          fileName: 'vacation_photo.jpg',
          totalBytes: 2 * 1024 * 1024,
          chunkSize: 64 * 1024,
          sha256Checksum: 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899',
          mimeType: 'image/jpeg',
        );

        final completedTask = _MockTransferTask(
          metadata: metadata,
          progressStream: const Stream.empty(),
        ).._status = TransferStatus.completed;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TransferProgressCard(
                container: container,
                initialTransfers: [completedTask],
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('vacation_photo.jpg'), findsOneWidget);
        expect(find.text('Verified successfully'), findsOneWidget);
        expect(find.byTooltip('Cancel transfer'), findsNothing);
        expect(find.text('Share again'), findsOneWidget);
        expect(find.text('Done'), findsOneWidget);

        // Tap Done button
        await tester.tap(find.text('Done'));
        await tester.pump();
      },
    );
  });
}

class _MockTransferTask implements TransferTask {
  @override
  final TransferMetadata metadata;
  @override
  final Stream<TransferProgress> progressStream;

  TransferStatus _status = TransferStatus.transferring;

  _MockTransferTask({required this.metadata, required this.progressStream});

  @override
  TransferStatus get status => _status;

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> pause() async {
    _status = TransferStatus.paused;
  }

  @override
  Future<void> resume() async {
    _status = TransferStatus.transferring;
  }

  @override
  Future<void> cancel([String? reason]) async {
    _status = TransferStatus.cancelled;
  }

  @override
  String get transferId => metadata.transferId;

  @override
  String get remoteDeviceId => 'remote_device_test';
}
