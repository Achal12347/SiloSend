import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/ui/transfer/incoming_transfer_dialog.dart';

void main() {
  group('IncomingTransferDialog Widget Tests', () {
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

    testWidgets('renders file metadata and accept/decline buttons truthfully', (
      tester,
    ) async {
      bool accepted = false;
      bool declined = false;

      final metadata = TransferMetadata(
        transferId: '0123456789abcdef0123456789abcdef',
        fileName: 'confidential_project.pdf',
        totalBytes: 5 * 1024 * 1024, // 5 MB
        chunkSize: 64 * 1024,
        sha256Checksum:
            'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        mimeType: 'application/pdf',
      );

      final request = IncomingTransferRequest(
        transferId: metadata.transferId,
        senderDeviceId: 'aabbccddeeff00112233445566778899',
        metadata: metadata,
        onAccept: (savePath) async {
          accepted = true;
          return _DummyTransferTask(metadata: metadata);
        },
        onDecline: ([reason]) async {
          declined = true;
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IncomingTransferDialog(
              request: request,
              container: container,
            ),
          ),
        ),
      );

      // Verify title and file metadata rendered
      expect(find.text('Incoming file'), findsOneWidget);
      expect(find.text('confidential_project.pdf'), findsOneWidget);
      expect(find.text('5.0 MB'), findsOneWidget);

      // Verify Action buttons rendered
      expect(find.text('Decline'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);

      // Verify Decline action
      await tester.tap(find.text('Decline'));
      await tester.pump();
      expect(declined, isTrue);
      expect(accepted, isFalse);
    });
  });
}

class _DummyTransferTask implements TransferTask {
  @override
  final TransferMetadata metadata;

  _DummyTransferTask({required this.metadata});

  @override
  TransferStatus get status => TransferStatus.transferring;

  @override
  Stream<TransferProgress> get progressStream => const Stream.empty();

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> cancel([String? reason]) async {}

  @override
  String get transferId => metadata.transferId;

  @override
  String get remoteDeviceId => 'dummy_remote';
}
