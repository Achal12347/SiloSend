@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/battery/system_battery_provider.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/file/system_file_picker_service.dart';
import 'package:vayu/core/file/system_storage_service.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/session/session_lifecycle_policy.dart';
import 'package:vayu/core/transfer/file_sharing_coordinator.dart';
import 'package:vayu/core/transfer/transfer_batch.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/core/transfer/transfer_engine_impl.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/core/transport/smart_transport_selector_impl.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/transfer/content_uri_payload_source.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/platform/system_platform_service.dart';

void main() {
  group('Phase 9 FileSharingCoordinator End-to-End Tests', () {
    late LocalDeviceIdentity identityA;
    late LocalDeviceIdentity identityB;
    late LanConnectionServer serverB;
    late ConnectionManager managerA;
    late ConnectionManager managerB;
    late CryptoService cryptoService;
    late SecureSessionManager secureManagerA;
    late SecureSessionManager secureManagerB;
    late TransferEngineImpl engineA;
    late TransferEngineImpl engineB;
    late SmartTransportSelectorImpl selectorA;
    late SmartTransportSelectorImpl selectorB;
    late Directory tempDirA;
    late Directory tempDirB;
    late SystemStorageService storageServiceA;
    late SystemStorageService storageServiceB;
    late FileSharingCoordinator coordinatorA;
    late FileSharingCoordinator coordinatorB;

    setUp(() async {
      tempDirA = Directory.systemTemp.createTempSync('vayu_coordinator_a_');
      tempDirB = Directory.systemTemp.createTempSync('vayu_coordinator_b_');

      identityA = LocalDeviceIdentity.generate(
        displayName: 'Sender-Android-A',
        platform: 'android',
      );
      identityB = LocalDeviceIdentity.generate(
        displayName: 'Receiver-Android-B',
        platform: 'android',
      );

      serverB = LanConnectionServer(requestedPort: 0);
      await serverB.start();

      managerA = ConnectionManager(
        localIdentity: identityA,
        handshakeTimeout: const Duration(seconds: 5),
      );
      managerB = ConnectionManager(
        localIdentity: identityB,
        handshakeTimeout: const Duration(seconds: 5),
      );
      managerB.registerLanServer(serverB);

      cryptoService = CryptoService();
      final keyStoreA = InMemorySecureKeyStore();
      final keyStoreB = InMemorySecureKeyStore();
      final trustStoreA = PeerTrustStore();
      final trustStoreB = PeerTrustStore();

      secureManagerA = SecureSessionManager(
        cryptoService: cryptoService,
        trustStore: trustStoreA,
        secureKeyStore: keyStoreA,
        localIdentity: identityA,
      );
      secureManagerB = SecureSessionManager(
        cryptoService: cryptoService,
        trustStore: trustStoreB,
        secureKeyStore: keyStoreB,
        localIdentity: identityB,
      );

      await secureManagerA.getOrInitializeLocalKeypair();
      await secureManagerB.getOrInitializeLocalKeypair();

      secureManagerA.attachToConnectionManager(managerA);
      secureManagerB.attachToConnectionManager(managerB);

      engineA = TransferEngineImpl(
        localDeviceId: identityA.idHex,
        secureSessionManager: secureManagerA,
      );
      engineB = TransferEngineImpl(
        localDeviceId: identityB.idHex,
        secureSessionManager: secureManagerB,
      );

      final battery = SystemBatteryProvider();
      final platform = SystemPlatformService();

      selectorA = SmartTransportSelectorImpl(
        platformService: platform,
        batteryProvider: battery,
        connectionManager: managerA,
        secureSessionManager: secureManagerA,
      );
      selectorB = SmartTransportSelectorImpl(
        platformService: platform,
        batteryProvider: battery,
        connectionManager: managerB,
        secureSessionManager: secureManagerB,
      );

      storageServiceA = SystemStorageService(
        customDownloadsDirectory: tempDirA.path,
      );
      storageServiceB = SystemStorageService(
        customDownloadsDirectory: tempDirB.path,
      );

      coordinatorA = FileSharingCoordinator(
        transferEngine: engineA,
        transportSelector: selectorA,
        filePickerService: SystemFilePickerService(),
        storageService: storageServiceA,
        secureSessionManager: secureManagerA,
        sessionLifecyclePolicy: SessionLifecyclePolicy(
          idleTimeout: const Duration(seconds: 30),
        ),
      );
      coordinatorB = FileSharingCoordinator(
        transferEngine: engineB,
        transportSelector: selectorB,
        filePickerService: SystemFilePickerService(),
        storageService: storageServiceB,
        secureSessionManager: secureManagerB,
        sessionLifecyclePolicy: SessionLifecyclePolicy(
          idleTimeout: const Duration(seconds: 30),
        ),
      );
    });

    tearDown(() async {
      coordinatorA.dispose();
      coordinatorB.dispose();
      engineA.dispose();
      engineB.dispose();
      secureManagerA.dispose();
      secureManagerB.dispose();
      managerA.dispose();
      managerB.dispose();
      await serverB.stop();

      try {
        if (tempDirA.existsSync()) tempDirA.deleteSync(recursive: true);
      } catch (_) {}
      try {
        if (tempDirB.existsSync()) tempDirB.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('Full End-to-End File Sharing Flow with SAF Stream Source and SHA-256 Verification', () async {
      // Create 70 KB test payload (multi-chunk crossing 64 KiB chunk boundary)
      final rawData = Uint8List.fromList(
        List.generate(70 * 1024, (i) => (i * 37 + 13) % 256),
      );
      final expectedSha256 = crypto.sha256.convert(rawData).toString();

      final selectedDoc = SelectedDocument(
        identifier: 'content://com.achyrio.vayu.provider/docs/report.pdf',
        name: 'report.pdf',
        sizeBytes: rawData.length,
        mimeType: 'application/pdf',
      );

      // Custom coordinator using test picker and test storage

      final customCoordinatorA = FileSharingCoordinator(
        transferEngine: engineA,
        transportSelector: selectorA,
        filePickerService: _TestDocumentPickerService(
          document: selectedDoc,
          data: rawData,
        ),
        storageService: storageServiceA,
        secureSessionManager: secureManagerA,
        sessionLifecyclePolicy: SessionLifecyclePolicy(
          idleTimeout: const Duration(seconds: 30),
        ),
      );

      final peerB = DiscoveredPeer(
        deviceId: identityB.idHex,
        displayName: identityB.displayName,
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan},
        endpointAddress: '127.0.0.1:${serverB.boundPort}',
        rssi: -50,
        lastSeen: DateTime.now(),
      );

      final receiverCompleter = Completer<TransferTask>();
      coordinatorB.incomingRequests.listen((req) async {
        final rxTask = await coordinatorB.acceptIncomingTransfer(req);
        receiverCompleter.complete(rxTask);
      });

      // Sender initiates transfer
      final task = await customCoordinatorA.sendFileToPeer(peerB);
      expect(task, isNotNull);

      final receiverTask = await receiverCompleter.future;

      // Await completion of transfer on both sender and receiver
      await Future.wait([task!.done, receiverTask.done]);
      expect(task.status, TransferStatus.completed);
      expect(receiverTask.status, TransferStatus.completed);

      // Verify file written on receiver device
      final expectedFilePath = '${tempDirB.path}/report.pdf';
      final receivedFile = File(expectedFilePath);
      expect(receivedFile.existsSync(), isTrue);

      final savedBytes = await receivedFile.readAsBytes();
      expect(savedBytes.length, rawData.length);
      expect(crypto.sha256.convert(savedBytes).toString(), expectedSha256);

      customCoordinatorA.dispose();
    });

    test(
      'Receiver Decline flow terminates transfer and cleans up staging file',
      () async {
        final rawData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        final selectedDoc = SelectedDocument(
          identifier: 'content://docs/secret.txt',
          name: 'secret.txt',
          sizeBytes: rawData.length,
        );

        final customCoordinatorA = FileSharingCoordinator(
          transferEngine: engineA,
          transportSelector: selectorA,
          filePickerService: _TestDocumentPickerService(
            document: selectedDoc,
            data: rawData,
          ),
          storageService: storageServiceA,
          secureSessionManager: secureManagerA,
          sessionLifecyclePolicy: SessionLifecyclePolicy(),
        );

        final peerB = DiscoveredPeer(
          deviceId: identityB.idHex,
          displayName: identityB.displayName,
          transportType: TransportType.lan,
          availableTransports: {TransportType.lan},
          endpointAddress: '127.0.0.1:${serverB.boundPort}',
          rssi: -50,
          lastSeen: DateTime.now(),
        );

        // Receiver explicitly declines
        coordinatorB.incomingRequests.listen((req) async {
          await coordinatorB.declineIncomingTransfer(
            req,
            reason: 'User declined transfer',
          );
        });

        final task = await customCoordinatorA.sendFileToPeer(peerB);
        expect(task, isNotNull);

        try {
          await task!.done;
        } catch (e) {
          expect(e, isA<TransferCancelledException>());
        }

        expect(task!.status, TransferStatus.cancelled);
        expect(File('${tempDirB.path}/secret.txt').existsSync(), isFalse);

        customCoordinatorA.dispose();
      },
    );

    test('Share Again retains peer identity and allows re-sending to same peer (R14)', () async {
      final peerB = DiscoveredPeer(
        deviceId: identityB.idHex,
        displayName: identityB.displayName,
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan},
        endpointAddress: '127.0.0.1:${serverB.boundPort}',
        rssi: -50,
        lastSeen: DateTime.now(),
      );

      // Pre-register peer in coordinator
      coordinatorA.rememberPeer(peerB);
      expect(coordinatorA.getKnownPeer(peerB.deviceId), isNotNull);
      expect(
        coordinatorA.getKnownPeer(peerB.deviceId)!.displayName,
        identityB.displayName,
      );

      // Prepare test doc
      final rawData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final testDoc = SelectedDocument(
        identifier: 'content://test/share_again.bin',
        name: 'share_again.bin',
        sizeBytes: rawData.length,
      );

      final customCoordinatorA = FileSharingCoordinator(
        transferEngine: engineA,
        transportSelector: selectorA,
        filePickerService: _TestDocumentPickerService(
          document: testDoc,
          data: rawData,
        ),
        storageService: storageServiceA,
        secureSessionManager: secureManagerA,
        sessionLifecyclePolicy: SessionLifecyclePolicy(),
      );
      customCoordinatorA.rememberPeer(peerB);

      coordinatorB.incomingRequests.listen((req) async {
        await coordinatorB.acceptIncomingTransfer(req);
      });

      // Trigger shareAgain using peerDeviceId
      final task = await customCoordinatorA.shareAgain(peerB.deviceId);
      expect(task, isNotNull);
      expect(customCoordinatorA.getPeerForTask(task!.transferId), isNotNull);

      await task.done;
      expect(task.status, TransferStatus.completed);

      // Verify task can be dismissed via Done (R14)
      expect(
        customCoordinatorA.allTransfers.any(
          (t) => t.transferId == task.transferId,
        ),
        isTrue,
      );
      customCoordinatorA.dismissCompletedTask(task.transferId);
      expect(
        customCoordinatorA.allTransfers.any(
          (t) => t.transferId == task.transferId,
        ),
        isFalse,
      );

      customCoordinatorA.dispose();
    });

    test('Share Again after grace teardown: transfer -> grace teardown disconnect -> share again -> reconnect -> second transfer', () async {
      final peerB = DiscoveredPeer(
        deviceId: identityB.idHex,
        displayName: identityB.displayName,
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan},
        endpointAddress: '127.0.0.1:${serverB.boundPort}',
        rssi: -50,
        lastSeen: DateTime.now(),
      );

      final testDoc = SelectedDocument(
        identifier: 'content://test/reconnect.bin',
        name: 'reconnect.bin',
        sizeBytes: 4,
      );

      final policyA = SessionLifecyclePolicy(
        postTransferGracePeriod: const Duration(milliseconds: 150),
        onDisconnectSession: (sid, reason) async {
          managerA.disconnectSession(sid, reason: reason);
        },
      );

      final customCoordinatorA = FileSharingCoordinator(
        transferEngine: engineA,
        transportSelector: selectorA,
        filePickerService: _TestDocumentPickerService(
          document: testDoc,
          data: Uint8List.fromList([1, 2, 3, 4]),
        ),
        storageService: storageServiceA,
        secureSessionManager: secureManagerA,
        sessionLifecyclePolicy: policyA,
      );
      customCoordinatorA.rememberPeer(peerB);

      final rxTasks = <TransferTask>[];
      final sub = coordinatorB.incomingRequests.listen((req) async {
        final rxTask = await coordinatorB.acceptIncomingTransfer(req);
        rxTasks.add(rxTask);
      });

      // 1. Initial transfer
      final task1 = await customCoordinatorA.sendFileToPeer(peerB);
      expect(task1, isNotNull);
      await task1!.done;
      while (rxTasks.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await rxTasks[0].done;
      expect(task1.status, TransferStatus.completed);

      // 2. Wait for grace teardown (150ms) to disconnect the session
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(managerA.activeSessions.isEmpty, isTrue);

      // 3. Known peer identity MUST be preserved after disconnect
      final knownPeer = customCoordinatorA.getKnownPeer(peerB.deviceId);
      expect(knownPeer, isNotNull);
      expect(knownPeer!.displayName, identityB.displayName);

      // 4. Share Again re-establishes connection and completes second transfer
      final task2 = await customCoordinatorA.shareAgain(peerB.deviceId);
      expect(task2, isNotNull);
      await task2!.done;
      while (rxTasks.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await rxTasks[1].done;
      expect(task2.status, TransferStatus.completed);

      await sub.cancel();
      customCoordinatorA.dispose();
      policyA.dispose();
    });

    test('Regression Issue 2: Receiver completion invokes markTransferEnded exactly once', () async {
      final countingPolicyB = _CountingSessionLifecyclePolicy(
        idleTimeout: const Duration(seconds: 30),
      );
      final customCoordinatorB = FileSharingCoordinator(
        transferEngine: engineB,
        transportSelector: selectorB,
        filePickerService: SystemFilePickerService(),
        storageService: storageServiceB,
        secureSessionManager: secureManagerB,
        sessionLifecyclePolicy: countingPolicyB,
      );

      final rawData = Uint8List.fromList([10, 20, 30, 40]);
      final testDoc = SelectedDocument(
        identifier: 'content://test/single_count.bin',
        name: 'single_count.bin',
        sizeBytes: rawData.length,
      );

      final customCoordinatorA = FileSharingCoordinator(
        transferEngine: engineA,
        transportSelector: selectorA,
        filePickerService: _TestDocumentPickerService(
          document: testDoc,
          data: rawData,
        ),
        storageService: storageServiceA,
        secureSessionManager: secureManagerA,
        sessionLifecyclePolicy: SessionLifecyclePolicy(
          idleTimeout: const Duration(seconds: 30),
        ),
      );

      final peerB = DiscoveredPeer(
        deviceId: identityB.idHex,
        displayName: identityB.displayName,
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan},
        endpointAddress: '127.0.0.1:${serverB.boundPort}',
        rssi: -50,
        lastSeen: DateTime.now(),
      );

      final rxDoneCompleter = Completer<void>();
      customCoordinatorB.incomingRequests.listen((req) async {
        final rxTask = await customCoordinatorB.acceptIncomingTransfer(req);
        await rxTask.done;
        rxDoneCompleter.complete();
      });

      final txTask = await customCoordinatorA.sendFileToPeer(peerB);
      expect(txTask, isNotNull);
      await txTask!.done;
      await rxDoneCompleter.future;

      // Verify markTransferEnded was called exactly once on receiver
      expect(countingPolicyB.markTransferEndedCount, 1);

      customCoordinatorA.dispose();
      customCoordinatorB.dispose();
    });

    test('Issue 5 Multi-File: Sequential batch transfer reuses authenticated session for multiple files', () async {
      final data1 = Uint8List.fromList([1, 2, 3, 4, 5]);
      final data2 = Uint8List.fromList([6, 7, 8, 9, 10, 11]);
      final doc1 = SelectedDocument(
        identifier: 'content://test/batch_file1.txt',
        name: 'batch_file1.txt',
        sizeBytes: data1.length,
      );
      final doc2 = SelectedDocument(
        identifier: 'content://test/batch_file2.txt',
        name: 'batch_file2.txt',
        sizeBytes: data2.length,
      );

      final multiPicker = _TestDocumentPickerService.multi({
        doc1.identifier: data1,
        doc2.identifier: data2,
      });

      final customCoordinatorA = FileSharingCoordinator(
        transferEngine: engineA,
        transportSelector: selectorA,
        filePickerService: multiPicker,
        storageService: storageServiceA,
        secureSessionManager: secureManagerA,
        sessionLifecyclePolicy: SessionLifecyclePolicy(
          idleTimeout: const Duration(seconds: 30),
        ),
      );

      final peerB = DiscoveredPeer(
        deviceId: identityB.idHex,
        displayName: identityB.displayName,
        transportType: TransportType.lan,
        availableTransports: {TransportType.lan},
        endpointAddress: '127.0.0.1:${serverB.boundPort}',
        rssi: -50,
        lastSeen: DateTime.now(),
      );

      // One decision for both files; no per-file prompt may appear.
      var singlePrompts = 0;
      coordinatorB.incomingRequests.listen((_) => singlePrompts++);
      final batchPrompts = <IncomingBatchRequest>[];
      coordinatorB.incomingBatchRequests.listen((req) {
        batchPrompts.add(req);
        coordinatorB.acceptIncomingBatch(req);
      });

      final tasks = await customCoordinatorA.sendFilesToPeer(
        peer: peerB,
        documents: [doc1, doc2],
      );

      expect(batchPrompts, hasLength(1));
      expect(batchPrompts.single.files.map((f) => f.fileName), [
        'batch_file1.txt',
        'batch_file2.txt',
      ]);
      expect(singlePrompts, 0);
      expect(tasks.length, 2);
      expect(tasks[0].status, TransferStatus.completed);
      expect(tasks[1].status, TransferStatus.completed);

      final rxBatch = coordinatorB.getBatch(batchPrompts.single.batchId)!;
      await Future.wait(rxBatch.tasks.values.map((t) => t.done));
      await _until(() => rxBatch.state == TransferBatchState.completed);

      // Verify both files exist on receiver
      final file1 = File('${tempDirB.path}/batch_file1.txt');
      final file2 = File('${tempDirB.path}/batch_file2.txt');
      expect(file1.existsSync(), isTrue);
      expect(file2.existsSync(), isTrue);
      expect(await file1.readAsBytes(), data1);
      expect(await file2.readAsBytes(), data2);

      customCoordinatorA.dispose();
    });

    DiscoveredPeer peerOfB() => DiscoveredPeer(
      deviceId: identityB.idHex,
      displayName: identityB.displayName,
      transportType: TransportType.lan,
      availableTransports: {TransportType.lan},
      endpointAddress: '127.0.0.1:${serverB.boundPort}',
      rssi: -50,
      lastSeen: DateTime.now(),
    );

    List<SelectedDocument> docsFor(Map<String, Uint8List> files) => [
      for (final e in files.entries)
        SelectedDocument(
          identifier: e.key,
          name: e.key.split('/').last,
          sizeBytes: e.value.length,
        ),
    ];

    FileSharingCoordinator senderWith(
      FilePickerService picker, {
      TransferEngine? engine,
      Duration autoResumeDelay = const Duration(seconds: 3),
    }) => FileSharingCoordinator(
      autoResumeDelay: autoResumeDelay,
      transferEngine: engine ?? engineA,
      transportSelector: selectorA,
      filePickerService: picker,
      storageService: storageServiceA,
      secureSessionManager: secureManagerA,
      sessionLifecyclePolicy: SessionLifecyclePolicy(
        idleTimeout: const Duration(seconds: 30),
      ),
    );

    test('A declined batch sends no files and tells the sender', () async {
      final files = {
        'content://t/a.txt': Uint8List.fromList([1]),
        'content://t/b.txt': Uint8List.fromList([2]),
      };
      final sender = senderWith(_TestDocumentPickerService.multi(files));
      var singlePrompts = 0;
      coordinatorB.incomingRequests.listen((_) => singlePrompts++);
      coordinatorB.incomingBatchRequests.listen(
        (req) => coordinatorB.declineIncomingBatch(req, reason: 'No thanks'),
      );

      await expectLater(
        sender.sendFilesToPeer(peer: peerOfB(), documents: docsFor(files)),
        throwsA(
          isA<TransferBatchDeclinedException>().having(
            (e) => e.reason,
            'reason',
            TransferCancelReason.declined,
          ),
        ),
      );
      final batch = sender.latestBatchForPeer(identityB.idHex)!;
      expect(batch.state, TransferBatchState.declined);
      expect(batch.tasks, isEmpty);
      expect(singlePrompts, 0);
      expect(tempDirB.listSync(), isEmpty);
      sender.dispose();
    });

    test(
      'A folder arrives with its structure and cannot leave the save folder',
      () async {
        final files = {
          'content://t/cover.jpg': Uint8List.fromList([1, 2, 3]),
          'content://t/day1.jpg': Uint8List.fromList([4, 5]),
          'content://t/evil.txt': Uint8List.fromList([6]),
        };
        final folders = {
          'content://t/cover.jpg': 'Trip',
          'content://t/day1.jpg': 'Trip/2024/June',
          // A hostile sender trying to write outside the save folder.
          'content://t/evil.txt': '../../outside',
        };
        final sender = senderWith(_TestDocumentPickerService.multi(files));
        coordinatorB.incomingBatchRequests.listen(
          coordinatorB.acceptIncomingBatch,
        );

        await sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: [
            for (final d in docsFor(files))
              SelectedDocument(
                identifier: d.identifier,
                name: d.name,
                sizeBytes: d.sizeBytes,
                folder: folders[d.identifier],
              ),
          ],
        );
        final rx = coordinatorB.latestBatchForPeer(
          identityA.idHex,
          outbound: false,
        )!;
        await _until(() => rx.state == TransferBatchState.completed);

        final sep = Platform.pathSeparator;
        expect(
          File('${tempDirB.path}${sep}Trip${sep}cover.jpg').readAsBytesSync(),
          files['content://t/cover.jpg'],
        );
        expect(
          File('${tempDirB.path}${sep}Trip${sep}2024${sep}June${sep}day1.jpg')
              .readAsBytesSync(),
          files['content://t/day1.jpg'],
        );
        // ".." parts are dropped, so the file stays inside the save folder.
        expect(
          File('${tempDirB.path}${sep}outside${sep}evil.txt').existsSync(),
          isTrue,
        );
        expect(
          File('${tempDirB.parent.path}${sep}outside').existsSync(),
          isFalse,
        );
        sender.dispose();
      },
    );

    test('Only the most recent finished batches stay in memory', () async {
      final files = {
        'content://t/p.txt': Uint8List.fromList([7]),
        'content://t/q.txt': Uint8List.fromList([8]),
      };
      final sender = senderWith(_TestDocumentPickerService.multi(files));
      coordinatorB.incomingBatchRequests.listen(
        coordinatorB.acceptIncomingBatch,
      );
      final ids = <String>[];
      for (var i = 0; i < FileSharingCoordinator.keepFinishedBatches + 2; i++) {
        await sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: docsFor(files),
        );
        final batch = sender.latestBatchForPeer(identityB.idHex)!;
        await _until(() => batch.isFinished);
        ids.add(batch.batchId);
      }
      await _until(() => sender.getBatch(ids[1]) == null);
      expect(sender.getBatch(ids.first), isNull);
      expect(sender.getBatch(ids.last), isNotNull);
      sender.dispose();
    });

    group('Same-name receives', () {
      // Two different sources that the receiver sees under one file name.
      Uint8List bytes(int seed, int size) => Uint8List.fromList(
        List<int>.generate(size, (i) => (i * seed) & 0xFF),
      );
      const size = 4 * 1024 * 1024;
      final sep = Platform.pathSeparator;

      List<File> receivedFiles() => tempDirB
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('.vayu.tmp'))
          .toList();

      SelectedDocument named(String id, String name, int length) =>
          SelectedDocument(identifier: id, name: name, sizeBytes: length);

      Future<List<TransferTask>> acceptAll() async {
        final tasks = <TransferTask>[];
        coordinatorB.incomingRequests.listen((request) async {
          tasks.add(await coordinatorB.acceptIncomingTransfer(request));
        });
        return tasks;
      }

      Future<void> sendBoth(Map<String, Uint8List> files, String name) async {
        final sender = senderWith(_TestDocumentPickerService.multi(files));
        // Connect once first: this test is about the receiver, not about two
        // sends racing to open the first connection.
        await selectorA.connectWithSmartSelection(
          peerOfB(),
          request: TransportSelectionRequest(targetPeer: peerOfB()),
        );
        await Future.wait([
          for (final e in files.entries)
            sender.sendFilesToPeer(
              peer: peerOfB(),
              documents: [named(e.key, name, e.value.length)],
            ),
        ]);
        sender.dispose();
      }

      test('simultaneous transfers with one name keep both files', () async {
        final a = bytes(3, size);
        final b = bytes(7, size);
        final tasks = await acceptAll();
        await sendBoth({'content://a/x': a, 'content://b/x': b}, 'same.bin');
        await _until(
          () =>
              tasks.length == 2 &&
              tasks.every((t) => t.status == TransferStatus.completed),
          timeout: const Duration(seconds: 30),
        );

        final files = receivedFiles();
        expect(files.map((f) => f.path.split(sep).last).toSet(), {
          'same.bin',
          'same (1).bin',
        });
        final digests = files
            .map((f) => crypto.sha256.convert(f.readAsBytesSync()).toString())
            .toSet();
        expect(digests, {
          crypto.sha256.convert(a).toString(),
          crypto.sha256.convert(b).toString(),
        });
        expect(
          tempDirB.listSync().where((e) => e.path.endsWith('.vayu.tmp')),
          isEmpty,
        );
      });

      test(
        'simultaneous identical files with one name are both kept',
        () async {
          final data = bytes(5, size);
          final tasks = await acceptAll();
          await sendBoth({
            'content://a/x': data,
            'content://b/x': Uint8List.fromList(data),
          }, 'twin.bin');
          await _until(
            () =>
                tasks.length == 2 &&
                tasks.every((t) => t.status == TransferStatus.completed),
            timeout: const Duration(seconds: 30),
          );

          // Equal checksums cannot show that two copies exist: count the files.
          final files = receivedFiles();
          expect(files, hasLength(2));
          for (final f in files) {
            expect(f.readAsBytesSync(), data);
          }
        },
      );

      test('an existing file with the same name is never replaced', () async {
        final existing = File('${tempDirB.path}${sep}keep.bin')
          ..writeAsStringSync('original');
        final incoming = bytes(9, 1024 * 1024);
        final tasks = await acceptAll();
        final sender = senderWith(
          _TestDocumentPickerService.multi({'content://k/x': incoming}),
        );
        await sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: [named('content://k/x', 'keep.bin', incoming.length)],
        );
        await _until(
          () =>
              tasks.length == 1 &&
              tasks.single.status == TransferStatus.completed,
          timeout: const Duration(seconds: 30),
        );
        expect(existing.readAsStringSync(), 'original');
        expect(
          File('${tempDirB.path}${sep}keep (1).bin').readAsBytesSync(),
          incoming,
        );
        sender.dispose();
      });

      test(
        'a file that appears at the destination mid-transfer survives',
        () async {
          final incoming = bytes(11, size);
          final tasks = <TransferTask>[];
          coordinatorB.incomingRequests.listen((request) async {
            final task = await coordinatorB.acceptIncomingTransfer(request);
            // Someone else saves a file under the same name meanwhile.
            File('${tempDirB.path}${sep}late.bin').writeAsStringSync('theirs');
            tasks.add(task);
          });
          final sender = senderWith(
            _TestDocumentPickerService.multi({'content://l/x': incoming}),
          );
          await sender.sendFilesToPeer(
            peer: peerOfB(),
            documents: [named('content://l/x', 'late.bin', incoming.length)],
          );
          await _until(
            () =>
                tasks.length == 1 &&
                tasks.single.status == TransferStatus.completed,
            timeout: const Duration(seconds: 30),
          );
          expect(
            File('${tempDirB.path}${sep}late.bin').readAsStringSync(),
            'theirs',
          );
          final saved = receivedFiles().where(
            (f) => f.readAsBytesSync().length == incoming.length,
          );
          expect(saved, hasLength(1));
          expect(saved.single.readAsBytesSync(), incoming);
          sender.dispose();
        },
      );

      test('a cancelled transfer frees its name for the next one', () async {
        final first = bytes(13, 16 * 1024 * 1024);
        final second = bytes(17, 1024 * 1024);
        final tasks = await acceptAll();
        final sender = senderWith(
          _TestDocumentPickerService.multi({
            'content://c/1': first,
            'content://c/2': second,
          }),
        );
        final sending = sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: [named('content://c/1', 'again.bin', first.length)],
        );
        await _until(
          () => tasks.length == 1,
          timeout: const Duration(seconds: 10),
        );
        await tasks.single.cancel('test');
        await sending.catchError((_) => <TransferTask>[]);
        await _until(
          () => tempDirB.listSync().every((e) => !e.path.endsWith('.vayu.tmp')),
        );

        await sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: [named('content://c/2', 'again.bin', second.length)],
        );
        await _until(
          () =>
              tasks.length == 2 &&
              tasks.last.status == TransferStatus.completed,
          timeout: const Duration(seconds: 30),
        );
        expect(
          File('${tempDirB.path}${sep}again.bin').readAsBytesSync(),
          second,
        );
        expect(receivedFiles(), hasLength(1));
        sender.dispose();
      });
    });

    test('A peer without batch support is asked per file as before', () async {
      final files = {
        'content://t/old1.txt': Uint8List.fromList([1, 2]),
        'content://t/old2.txt': Uint8List.fromList([3, 4]),
      };
      final sender = senderWith(
        _TestDocumentPickerService.multi(files),
        engine: _NoBatchEngine(engineA),
      );
      var batchPrompts = 0;
      coordinatorB.incomingBatchRequests.listen((_) => batchPrompts++);
      final prompted = <String>[];
      coordinatorB.incomingRequests.listen((req) {
        prompted.add(req.metadata.fileName);
        coordinatorB.acceptIncomingTransfer(req);
      });

      final tasks = await sender.sendFilesToPeer(
        peer: peerOfB(),
        documents: docsFor(files),
      );
      expect(
        tasks.map((t) => t.status),
        everyElement(TransferStatus.completed),
      );
      expect(prompted, ['old1.txt', 'old2.txt']);
      expect(batchPrompts, 0);
      sender.dispose();
    });

    test('A dropped connection resumes the batch by itself', () async {
      final big = Uint8List.fromList(
        List<int>.generate(8 * 1024 * 1024, (i) => (i * 7) & 0xff),
      );
      final files = {
        'content://t/first.txt': Uint8List.fromList([1, 2, 3]),
        'content://t/big.bin': big,
      };
      final sender = senderWith(
        _TestDocumentPickerService.multi(files),
        autoResumeDelay: const Duration(milliseconds: 200),
      );
      String? batchId;
      coordinatorB.incomingBatchRequests.listen((req) {
        batchId = req.batchId;
        coordinatorB.acceptIncomingBatch(req);
      });

      final sending = sender.sendFilesToPeer(
        peer: peerOfB(),
        documents: docsFor(files),
        chunkSize: 64 * 1024,
      );
      // Drop the connection while the big file is on its way.
      await _until(() {
        final task = sender.latestBatchForPeer(identityB.idHex)?.tasks[1];
        final sent =
            (task as OutboundTransferTask?)?.lastProgress?.bytesTransferred;
        return sent != null && sent > 0;
      });
      await secureManagerA.getSessionForPeer(identityB.idHex)?.terminate();
      await sending;

      final batch = sender.latestBatchForPeer(identityB.idHex)!;
      // Nobody pressed Retry.
      await _until(
        () => batch.state == TransferBatchState.completed,
        timeout: const Duration(seconds: 20),
      );
      final rx = coordinatorB.getBatch(batchId!)!;
      await _until(() => rx.state == TransferBatchState.completed);
      // This test sends with a 64 KiB override while the automatic retry uses
      // the link's own chunk size, so the kept partial does not match (see
      // "A resumed file keeps its original name" for a real resume). The
      // partial stays kept for a later matching resume instead of being
      // overwritten, so the fresh copy takes the next free name.
      expect(File('${tempDirB.path}/big (1).bin').readAsBytesSync(), big);
      expect(File('${tempDirB.path}/big.bin.vayu.tmp').existsSync(), isTrue);
      sender.dispose();
    });

    test('A resumed file keeps its original name', () async {
      final big = Uint8List.fromList(
        List<int>.generate(24 * 1024 * 1024, (i) => (i * 13) & 0xff),
      );
      final files = {
        'content://r/first.txt': Uint8List.fromList([4, 5, 6]),
        'content://r/movie.bin': big,
      };
      // No chunk-size override: the retry uses the same size, so the kept
      // partial matches and is continued.
      final sender = senderWith(
        _TestDocumentPickerService.multi(files),
        autoResumeDelay: const Duration(milliseconds: 200),
      );
      String? batchId;
      coordinatorB.incomingBatchRequests.listen((req) {
        batchId = req.batchId;
        coordinatorB.acceptIncomingBatch(req);
      });
      final sending = sender.sendFilesToPeer(
        peer: peerOfB(),
        documents: docsFor(files),
      );
      await _until(() {
        final task = sender.latestBatchForPeer(identityB.idHex)?.tasks[1];
        final sent =
            (task as OutboundTransferTask?)?.lastProgress?.bytesTransferred;
        return sent != null && sent >= 4 * 1024 * 1024;
      }, timeout: const Duration(seconds: 20));
      await secureManagerA.getSessionForPeer(identityB.idHex)?.terminate();
      await sending;

      final batch = sender.latestBatchForPeer(identityB.idHex)!;
      await _until(
        () => batch.state == TransferBatchState.completed,
        timeout: const Duration(seconds: 30),
      );
      final rx = coordinatorB.getBatch(batchId!)!;
      await _until(() => rx.state == TransferBatchState.completed);
      expect(File('${tempDirB.path}/movie.bin').readAsBytesSync(), big);
      // Continued under its own name: no "(1)" copy, no leftover partial.
      expect(
        tempDirB
            .listSync()
            .map((e) => e.path.split(Platform.pathSeparator).last)
            .toSet(),
        {'first.txt', 'movie.bin'},
      );
      sender.dispose();
    });

    test(
      'One failed file does not stop the batch; retry resends only it',
      () async {
        final files = {
          'content://t/one.txt': Uint8List.fromList([1, 1, 1]),
          'content://t/two.txt': Uint8List.fromList([2, 2, 2]),
          'content://t/three.txt': Uint8List.fromList([3, 3, 3]),
        };
        final picker = _TestDocumentPickerService.multi(files)
          ..failOnce.add('content://t/two.txt');
        final sender = senderWith(picker);

        var singlePrompts = 0;
        coordinatorB.incomingRequests.listen((_) => singlePrompts++);
        String? batchId;
        coordinatorB.incomingBatchRequests.listen((req) {
          batchId = req.batchId;
          coordinatorB.acceptIncomingBatch(req);
        });

        await sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: docsFor(files),
        );
        final batch = sender.latestBatchForPeer(identityB.idHex)!;
        expect(batch.state, TransferBatchState.completedWithFailures);
        expect(batch.failures.keys, [1]);
        expect(batch.completedCount, 2);

        final firstTasks = Map.of(batch.tasks);
        await sender.retryFailedFiles(batch.batchId);
        expect(batch.state, TransferBatchState.completed);
        expect(batch.failures, isEmpty);
        // Files that already arrived were not sent again.
        expect(identical(batch.tasks[0], firstTasks[0]), isTrue);
        expect(identical(batch.tasks[2], firstTasks[2]), isTrue);
        expect(singlePrompts, 0);

        final rx = coordinatorB.getBatch(batchId!)!;
        await _until(() => rx.state == TransferBatchState.completed);
        expect(
          File('${tempDirB.path}/two.txt').readAsBytesSync(),
          files['content://t/two.txt'],
        );
        expect(tempDirB.listSync().whereType<File>(), hasLength(3));
        sender.dispose();
      },
    );

    test('Finished transfers are written to history on both sides', () async {
      final files = {
        'content://t/h1.txt': Uint8List.fromList([1, 2, 3]),
        'content://t/h2.txt': Uint8List.fromList([4, 5]),
      };
      final senderHistory = TransferHistory(InMemoryTransferHistoryStorage());
      final receiverHistory = TransferHistory(InMemoryTransferHistoryStorage());
      final sender = FileSharingCoordinator(
        transferEngine: engineA,
        transportSelector: selectorA,
        filePickerService: _TestDocumentPickerService.multi(files),
        storageService: storageServiceA,
        secureSessionManager: secureManagerA,
        sessionLifecyclePolicy: SessionLifecyclePolicy(
          idleTimeout: const Duration(seconds: 30),
        ),
        history: senderHistory,
      );
      final receiver = FileSharingCoordinator(
        transferEngine: engineB,
        transportSelector: selectorB,
        filePickerService: SystemFilePickerService(),
        storageService: storageServiceB,
        secureSessionManager: secureManagerB,
        sessionLifecyclePolicy: SessionLifecyclePolicy(
          idleTimeout: const Duration(seconds: 30),
        ),
        history: receiverHistory,
      );
      // Only this receiver answers; the default one stays silent.
      receiver.incomingBatchRequests.listen(receiver.acceptIncomingBatch);

      await sender.sendFilesToPeer(peer: peerOfB(), documents: docsFor(files));
      await _until(() => receiverHistory.records.length == 2);

      expect(senderHistory.records, hasLength(2));
      expect(
        senderHistory.records.every(
          (r) => r.outbound && r.outcome == TransferOutcome.completed,
        ),
        isTrue,
      );
      final received = receiverHistory.records.firstWhere(
        (r) => r.fileName == 'h1.txt',
      );
      expect(received.outbound, isFalse);
      expect(received.savedPath, '${tempDirB.path}/h1.txt');
      expect(received.batchId, isNotNull);
      sender.dispose();
      receiver.dispose();
    });

    test(
      'A sender holding the Receive ticket is accepted without a prompt',
      () async {
        final files = {
          'content://t/r1.jpg': Uint8List.fromList([7, 7, 7]),
        };
        final sender = senderWith(_TestDocumentPickerService.multi(files));
        const ticket = '00112233445566778899aabbccddeeff';

        // Receiver opens Receive; sender scanned its code.
        coordinatorB.startReceiveSession(ticket);
        sender.rememberReceiveTicket(identityB.idHex, ticket);

        var prompts = 0;
        coordinatorB.incomingBatchRequests.listen((_) => prompts++);
        coordinatorB.incomingRequests.listen((_) => prompts++);
        final accepted = <TransferBatch>[];
        coordinatorB.autoAcceptedBatches.listen(accepted.add);

        // Even a single file goes as a batch carrying the proof.
        final tasks = await sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: docsFor(files),
        );
        expect(tasks.single.status, TransferStatus.completed);
        expect(prompts, 0);
        expect(accepted, hasLength(1));
        await _until(
          () => accepted.single.state == TransferBatchState.completed,
        );
        expect(File('${tempDirB.path}/r1.jpg').readAsBytesSync(), [7, 7, 7]);
        sender.dispose();
      },
    );

    test('Without the ticket the receiver is still asked', () async {
      final files = {
        'content://t/x1.txt': Uint8List.fromList([1]),
      };
      final sender = senderWith(_TestDocumentPickerService.multi(files));
      // Receive is open, but this sender never scanned its code.
      coordinatorB.startReceiveSession('00112233445566778899aabbccddeeff');
      sender.rememberReceiveTicket(
        identityB.idHex,
        'ffeeddccbbaa99887766554433221100',
      );
      var autoAccepted = 0;
      coordinatorB.autoAcceptedBatches.listen((_) => autoAccepted++);
      final prompted = <IncomingBatchRequest>[];
      coordinatorB.incomingBatchRequests.listen((req) {
        prompted.add(req);
        coordinatorB.declineIncomingBatch(req);
      });

      await expectLater(
        sender.sendFilesToPeer(peer: peerOfB(), documents: docsFor(files)),
        throwsA(isA<TransferBatchDeclinedException>()),
      );
      expect(prompted, hasLength(1));
      expect(autoAccepted, 0);
      sender.dispose();
    });

    test('A closed Receive session no longer auto-accepts', () async {
      final files = {
        'content://t/y1.txt': Uint8List.fromList([2]),
      };
      final sender = senderWith(_TestDocumentPickerService.multi(files));
      const ticket = '00112233445566778899aabbccddeeff';
      coordinatorB.startReceiveSession(ticket);
      coordinatorB.endReceiveSession();
      sender.rememberReceiveTicket(identityB.idHex, ticket);
      final prompted = <IncomingBatchRequest>[];
      coordinatorB.incomingBatchRequests.listen((req) {
        prompted.add(req);
        coordinatorB.declineIncomingBatch(req);
      });

      await expectLater(
        sender.sendFilesToPeer(peer: peerOfB(), documents: docsFor(files)),
        throwsA(isA<TransferBatchDeclinedException>()),
      );
      expect(prompted, hasLength(1));
      sender.dispose();
    });

    test(
      'Off the Receive screen offers are declined without a prompt',
      () async {
        coordinatorB.acceptOffersOutsideReceive = false; // the app's default
        var prompts = 0;
        coordinatorB.incomingBatchRequests.listen((_) => prompts++);
        coordinatorB.incomingRequests.listen((_) => prompts++);

        // A batch: the sender learns why.
        final files = {
          'content://t/n1.txt': Uint8List.fromList([1]),
          'content://t/n2.txt': Uint8List.fromList([2]),
        };
        final sender = senderWith(_TestDocumentPickerService.multi(files));
        await expectLater(
          sender.sendFilesToPeer(peer: peerOfB(), documents: docsFor(files)),
          throwsA(
            isA<TransferBatchDeclinedException>().having(
              (e) => e.reason,
              'reason',
              TransferCancelReason.notReceiving,
            ),
          ),
        );

        // A single file: declined with the same reason in words.
        final doc = SelectedDocument(
          identifier: 'content://t/one.txt',
          name: 'one.txt',
          sizeBytes: 1,
        );
        final singleSender = senderWith(
          _TestDocumentPickerService(
            document: doc,
            data: Uint8List.fromList([9]),
          ),
        );
        final single = await singleSender.sendFileToPeer(
          peerOfB(),
          preselectedDoc: doc,
        );
        await expectLater(
          single!.done,
          throwsA(
            isA<TransferCancelledException>().having(
              (e) => e.reason,
              'reason',
              contains("isn't receiving"),
            ),
          ),
        );
        expect(prompts, 0);
        singleSender.dispose();

        // Opening Receive lets offers through again (asked as usual).
        coordinatorB.startReceiveSession('00112233445566778899aabbccddeeff');
        final asked = coordinatorB.incomingBatchRequests.first;
        final again = sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: docsFor(files),
        );
        final declined = expectLater(
          again,
          throwsA(isA<TransferBatchDeclinedException>()),
        );
        final request = await asked;
        await coordinatorB.declineIncomingBatch(request);
        await declined;
        sender.dispose();
      },
    );

    test(
      'An open Receive screen takes offers even without a valid code',
      () async {
        coordinatorB.acceptOffersOutsideReceive = false; // the app's setting
        final files = {
          'content://t/r1.txt': Uint8List.fromList([1]),
          'content://t/r2.txt': Uint8List.fromList([2]),
        };
        final sender = senderWith(_TestDocumentPickerService.multi(files));

        // Receive is open but no code could be made (or it expired): the
        // offer is still asked about, not declined.
        coordinatorB.openReceiveScreen();
        final asked = coordinatorB.incomingBatchRequests.first;
        final first = sender.sendFilesToPeer(
          peer: peerOfB(),
          documents: docsFor(files),
        );
        final declinedByUser = expectLater(
          first,
          throwsA(isA<TransferBatchDeclinedException>()),
        );
        await coordinatorB.declineIncomingBatch(await asked);
        await declinedByUser;

        // Receive closed: declined automatically again.
        coordinatorB.closeReceiveScreen();
        await expectLater(
          sender.sendFilesToPeer(peer: peerOfB(), documents: docsFor(files)),
          throwsA(
            isA<TransferBatchDeclinedException>().having(
              (e) => e.reason,
              'reason',
              TransferCancelReason.notReceiving,
            ),
          ),
        );
        sender.dispose();
      },
    );

    test(
      'A batch too big for free space is refused with the real reason',
      () async {
        final smallDisk = FileSharingCoordinator(
          transferEngine: engineB,
          transportSelector: selectorB,
          filePickerService: SystemFilePickerService(),
          storageService: _FixedFreeSpaceStorage(
            tempDirB.path,
            freeBytes: 1024,
          ),
          secureSessionManager: secureManagerB,
          sessionLifecyclePolicy: SessionLifecyclePolicy(
            idleTimeout: const Duration(seconds: 30),
          ),
        );
        final files = {
          'content://t/x.bin': Uint8List(10),
          'content://t/y.bin': Uint8List(10),
        };
        final sender = senderWith(_TestDocumentPickerService.multi(files));
        Object? receiverError;
        smallDisk.incomingBatchRequests.listen((req) async {
          try {
            await smallDisk.acceptIncomingBatch(req);
          } catch (e) {
            receiverError = e;
          }
        });

        await expectLater(
          sender.sendFilesToPeer(peer: peerOfB(), documents: docsFor(files)),
          throwsA(
            isA<TransferBatchDeclinedException>().having(
              (e) => e.outOfSpace,
              'outOfSpace',
              isTrue,
            ),
          ),
        );
        await _until(() => receiverError != null);
        expect(receiverError, isA<InsufficientStorageException>());
        sender.dispose();
        smallDisk.dispose();
      },
    );
  });
}

/// An engine that reports the peer has no batch support, like an older build.
class _NoBatchEngine implements TransferEngine {
  final TransferEngine inner;
  _NoBatchEngine(this.inner);

  @override
  bool supportsBatchOffers(String targetDeviceId) => false;

  @override
  bool supportsLateHash(String targetDeviceId) => false;

  @override
  int chunkSizeFor(String targetDeviceId) => inner.chunkSizeFor(targetDeviceId);

  @override
  Future<void> offerBatch({
    required String targetDeviceId,
    required String batchId,
    required List<BatchManifestEntry> files,
    Duration timeout = const Duration(minutes: 5),
    String? receiveProof,
  }) => throw UnsupportedError('old peer');

  @override
  Stream<IncomingBatchRequest> get incomingBatchRequests =>
      inner.incomingBatchRequests;

  @override
  Future<TransferTask> sendPayload({
    required String targetDeviceId,
    required PayloadSource source,
    required TransferMetadata metadata,
    Future<String>? lateSha256,
  }) => inner.sendPayload(
    targetDeviceId: targetDeviceId,
    source: source,
    metadata: metadata,
    lateSha256: lateSha256,
  );

  @override
  Stream<IncomingTransferRequest> get incomingTransferRequests =>
      inner.incomingTransferRequests;

  @override
  List<TransferTask> get activeTransfers => inner.activeTransfers;

  @override
  Future<void> dispose() async {}
}

class _FixedFreeSpaceStorage extends SystemStorageService {
  final int freeBytes;
  _FixedFreeSpaceStorage(String dir, {required this.freeBytes})
    : super(customDownloadsDirectory: dir);

  @override
  Future<int?> getFreeBytes(String directory) async => freeBytes;
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _CountingSessionLifecyclePolicy extends SessionLifecyclePolicy {
  int markTransferEndedCount = 0;
  int markTransferStartedCount = 0;

  _CountingSessionLifecyclePolicy({super.idleTimeout});

  @override
  void markTransferStarted(String sessionId) {
    markTransferStartedCount++;
    super.markTransferStarted(sessionId);
  }

  @override
  void markTransferEnded(String sessionId) {
    markTransferEndedCount++;
    super.markTransferEnded(sessionId);
  }
}

class _TestDocumentPickerService implements FilePickerService {
  final Map<String, Uint8List> _files;

  /// Identifiers whose first read fails, like a file briefly unavailable.
  final Set<String> failOnce = {};

  _TestDocumentPickerService({
    required SelectedDocument document,
    required Uint8List data,
  }) : _files = {document.identifier: data};

  _TestDocumentPickerService.multi(this._files);

  @override
  Future<SelectedDocument?> pickDocument() async {
    final entry = _files.entries.firstOrNull;
    if (entry == null) return null;
    return SelectedDocument(
      identifier: entry.key,
      name: entry.key.split('/').last,
      sizeBytes: entry.value.length,
    );
  }

  @override
  Future<List<SelectedDocument>> pickMultipleDocuments() async {
    return _files.entries
        .map(
          (e) => SelectedDocument(
            identifier: e.key,
            name: e.key.split('/').last,
            sizeBytes: e.value.length,
          ),
        )
        .toList();
  }

  @override
  Future<PickedFolder?> pickFolder() async => null;

  @override
  PayloadSource createPayloadSource(SelectedDocument doc) {
    final bytes = _files[doc.identifier] ?? Uint8List(0);
    return ContentUriPayloadSource(
      uri: doc.identifier,
      length: bytes.length,
      readChunkCallback: (uri, offset, length) async {
        if (failOnce.remove(uri)) {
          throw const FileSystemException('Temporarily unreadable');
        }
        final end = (offset + length).clamp(0, bytes.length);
        return Uint8List.fromList(bytes.sublist(offset, end));
      },
    );
  }
}
