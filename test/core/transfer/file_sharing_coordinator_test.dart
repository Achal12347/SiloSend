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
    }) => FileSharingCoordinator(
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
  int chunkSizeFor(String targetDeviceId) => inner.chunkSizeFor(targetDeviceId);

  @override
  Future<void> offerBatch({
    required String targetDeviceId,
    required String batchId,
    required List<BatchManifestEntry> files,
    Duration timeout = const Duration(minutes: 5),
  }) => throw UnsupportedError('old peer');

  @override
  Stream<IncomingBatchRequest> get incomingBatchRequests =>
      inner.incomingBatchRequests;

  @override
  Future<TransferTask> sendPayload({
    required String targetDeviceId,
    required PayloadSource source,
    required TransferMetadata metadata,
  }) => inner.sendPayload(
    targetDeviceId: targetDeviceId,
    source: source,
    metadata: metadata,
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

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
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
