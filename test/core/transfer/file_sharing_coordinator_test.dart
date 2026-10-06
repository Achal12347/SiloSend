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
import 'package:vayu/core/transfer/transfer_engine_impl.dart';
import 'package:vayu/core/transport/smart_transport_selector_impl.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/transfer/content_uri_payload_source.dart';
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

    test(
      'Share Again retains peer identity and allows re-sending to same peer (R14)',
      () async {
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
        expect(coordinatorA.getKnownPeer(peerB.deviceId)!.displayName, identityB.displayName);

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
        expect(customCoordinatorA.allTransfers.any((t) => t.transferId == task.transferId), isTrue);
        customCoordinatorA.dismissCompletedTask(task.transferId);
        expect(customCoordinatorA.allTransfers.any((t) => t.transferId == task.transferId), isFalse);

        customCoordinatorA.dispose();
      },
    );

    test(
      'Share Again after grace teardown: transfer -> grace teardown disconnect -> share again -> reconnect -> second transfer',
      () async {
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
      },
    );

    test(
      'Regression Issue 2: Receiver completion invokes markTransferEnded exactly once',
      () async {
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
      },
    );

    test(
      'Issue 5 Multi-File: Sequential batch transfer reuses authenticated session for multiple files',
      () async {
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

        final receivedFiles = <String>[];
        final receiverTasks = <TransferTask>[];
        final allReceivedCompleter = Completer<void>();

        coordinatorB.incomingRequests.listen((req) async {
          final rxTask = await coordinatorB.acceptIncomingTransfer(req);
          receiverTasks.add(rxTask);
          rxTask.done.whenComplete(() {
            receivedFiles.add(req.metadata.fileName);
          }).ignore();

          if (receiverTasks.length == 2) {
            allReceivedCompleter.complete();
          }
        });

        final tasks = await customCoordinatorA.sendFilesToPeer(
          peer: peerB,
          documents: [doc1, doc2],
        );

        await allReceivedCompleter.future;
        await Future.wait(receiverTasks.map((t) => t.done));

        expect(tasks.length, 2);
        expect(tasks[0].status, TransferStatus.completed);
        expect(tasks[1].status, TransferStatus.completed);
        expect(receivedFiles, containsAll(['batch_file1.txt', 'batch_file2.txt']));

        // Verify both files exist on receiver
        final file1 = File('${tempDirB.path}/batch_file1.txt');
        final file2 = File('${tempDirB.path}/batch_file2.txt');
        expect(file1.existsSync(), isTrue);
        expect(file2.existsSync(), isTrue);
        expect(await file1.readAsBytes(), data1);
        expect(await file2.readAsBytes(), data2);

        customCoordinatorA.dispose();
      },
    );
  });
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

  _TestDocumentPickerService({required SelectedDocument document, required Uint8List data})
      : _files = {document.identifier: data};

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
        final end = (offset + length).clamp(0, bytes.length);
        return Uint8List.fromList(bytes.sublist(offset, end));
      },
    );
  }
}
