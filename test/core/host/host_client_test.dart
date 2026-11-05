import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/file/system_storage_service.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/host/host_service.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/discovery/discovery_beacon.dart';
import 'package:vayu/domain/host/host_payloads.dart';
import 'package:vayu/domain/transfer/batch_payloads.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

import '../../ui/home/vayu_home_page_test.dart' show MockDiscoveryService;

/// A whole app (real sessions, coordinator, storage) on loopback.
class _Phone {
  final String name;
  final Directory dir = Directory.systemTemp.createTempSync('vayu_host_');
  final LanConnectionServer server = LanConnectionServer(requestedPort: 0);
  late final AppContainer app;

  _Phone(this.name);

  Future<void> start() async {
    await server.start();
    app = AppContainer.standard(
      storage: InMemoryIdentityStorage(
        LocalDeviceIdentity.generate(displayName: name, platform: 'android'),
      ),
      lanServer: server,
      storageService: SystemStorageService(
        customDownloadsDirectory: '${dir.path}/Downloads',
      ),
      discoveryCoordinator: DiscoveryCoordinator(
        services: [MockDiscoveryService(TransportType.lan)],
      ),
    );
    await app.initialize();
  }

  String get id => app.identity!.idHex;

  /// This phone knows where [other] is (as after discovery).
  void knows(_Phone other) => app.fileSharingCoordinator.rememberPeer(
    DiscoveredPeer(
      deviceId: other.id,
      displayName: other.name,
      transportType: TransportType.lan,
      availableTransports: const {TransportType.lan},
      rssi: 0,
      endpointAddress: '127.0.0.1:${other.server.boundPort}',
      transportEndpoints: {
        TransportType.lan: '127.0.0.1:${other.server.boundPort}',
      },
      lastSeen: DateTime.now(),
    ),
  );

  Future<void> stop() async {
    await app.stopDiscoveryAndAdvertising();
    app.dispose();
    await server.stop();
    // Windows can hold a just-closed file for a moment under load. A file
    // that really stays open still fails here.
    for (var attempt = 1; ; attempt++) {
      try {
        dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

File _file(Directory dir, String name, int size) {
  final random = Random(3);
  return File('${dir.path}/$name')..writeAsBytesSync(
    Uint8List.fromList(List.generate(size, (_) => random.nextInt(256))),
  );
}

void main() {
  late _Phone host;
  late _Phone client;

  setUp(() async {
    host = _Phone('Host phone');
    client = _Phone('Client phone');
    await host.start();
    await client.start();
    client.knows(host);
  });

  tearDown(() async {
    await client.stop();
    await host.stop();
  });

  test('a phone that is not hosting says so', () async {
    final catalog = await client.app.hostService.browse(host.id);
    expect(catalog.hosting, isFalse);
    expect(catalog.items, isEmpty);
  });

  test('browse, download: the file arrives intact without a prompt, '
      'though the client is not on its Receive screen', () async {
    final source = _file(host.dir, 'clip.bin', 300 * 1024 + 7);
    host.app.hostService.startHosting('Trip', [
      SelectedDocument(
        identifier: source.path,
        name: 'clip.bin',
        sizeBytes: source.lengthSync(),
        mimeType: 'application/octet-stream',
      ),
    ]);
    expect(host.app.hostService.isHosting, isTrue);

    final catalog = await client.app.hostService.browse(host.id);
    expect(catalog.hosting, isTrue);
    expect(catalog.shareName, 'Trip');
    expect(catalog.items.single.name, 'clip.bin');
    expect(catalog.items.single.sizeBytes, source.lengthSync());
    // The host knows who is browsing.
    expect(host.app.hostService.clients.single.name, 'Client phone');

    final arrived = client.app.fileSharingCoordinator.hostBatches.first;
    final answer = await client.app.hostService.download(host.id, [
      catalog.items.single.itemId,
    ]);
    expect(answer.accepted, isTrue);
    expect(answer.queued, isFalse);

    final batch = await arrived.timeout(const Duration(seconds: 20));
    expect(batch.fileCount, 1);
    final saved = File('${client.dir.path}/Downloads/clip.bin');
    for (var i = 0; i < 200 && !saved.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(saved.readAsBytesSync(), source.readAsBytesSync());
  });

  test('two requests to one host before the first batch arrives: '
      'both download without a prompt', () async {
    final a = _file(host.dir, 'a.bin', 200 * 1024);
    final b = _file(host.dir, 'b.bin', 150 * 1024 + 3);
    host.app.hostService.startHosting('Two', [
      for (final f in [a, b])
        SelectedDocument(
          identifier: f.path,
          name: f.uri.pathSegments.last,
          sizeBytes: f.lengthSync(),
        ),
    ]);
    final catalog = await client.app.hostService.browse(host.id);
    final arrived = client.app.fileSharingCoordinator.hostBatches
        .take(2)
        .toList();
    // Both asked at once: the second ticket used to replace the first.
    final answers = await Future.wait([
      for (final item in catalog.items)
        client.app.hostService.download(host.id, [item.itemId]),
    ]);
    expect(answers.every((r) => r.accepted), isTrue);
    final batches = await arrived.timeout(const Duration(seconds: 30));
    expect(batches.length, 2);
    for (final f in [a, b]) {
      final saved = File(
        '${client.dir.path}/Downloads/${f.uri.pathSegments.last}',
      );
      for (var i = 0; i < 200 && !saved.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(saved.readAsBytesSync(), f.readAsBytesSync());
    }
  });

  test('a batch proving the ticket but holding other files is not '
      'accepted without the user', () async {
    final asked = _file(host.dir, 'asked.bin', 1000);
    final other = _file(host.dir, 'other.bin', 2000);
    host.knows(client);
    const ticket = 'ab12ab12ab12ab12ab12ab12ab12ab12';
    client.app.fileSharingCoordinator.expectFromHost(host.id, ticket, [
      BatchManifestEntry(
        fileName: 'asked.bin',
        sizeBytes: asked.lengthSync(),
        mimeType: 'application/octet-stream',
      ),
    ]);
    var accepted = false;
    final sub = client.app.fileSharingCoordinator.hostBatches.listen(
      (_) => accepted = true,
    );
    final sending = host.app.fileSharingCoordinator.sendFilesToPeer(
      peer: host.app.fileSharingCoordinator.getKnownPeer(client.id)!,
      documents: [
        SelectedDocument(
          identifier: other.path,
          name: 'other.bin',
          sizeBytes: other.lengthSync(),
        ),
      ],
      receiveTicket: ticket,
    );
    // The client is not on Receive, so the unexpected batch is declined.
    await expectLater(sending, throwsA(isA<TransferBatchDeclinedException>()));
    expect(accepted, isFalse);
    expect(
      File('${client.dir.path}/Downloads/other.bin').existsSync(),
      isFalse,
    );
    await sub.cancel();
  });

  group('private host', () {
    late File source;
    setUp(() {
      source = _file(host.dir, 'secret.bin', 4000);
      host.app.hostService.startHosting('Private', [
        SelectedDocument(
          identifier: source.path,
          name: 'secret.bin',
          sizeBytes: 4000,
        ),
      ], access: HostAccess.private);
    });

    test('shows its name and that it is private, but no items, '
        'until the PIN is right', () async {
      final pin = host.app.hostService.pin!;
      expect(pin, matches(RegExp(r'^\d{6}$')));

      final locked = await client.app.hostService.browse(host.id);
      expect(locked.hosting, isTrue);
      expect(locked.shareName, 'Private');
      expect(locked.access, HostAccess.private);
      expect(locked.lock, HostLock.pinRequired);
      expect(locked.items, isEmpty);
      expect(
        host.app.hostService.clients.single.state,
        HostClientState.waitingForPin,
      );

      // Asking for files without the PIN is refused.
      final refused = await client.app.hostService.download(host.id, [
        'ab' * 16,
      ]);
      expect(refused.reason, HostDeclineReason.pinRequired);

      final wrong = await client.app.hostService.browse(
        host.id,
        pin: pin == '000000' ? '111111' : '000000',
      );
      expect(wrong.lock, HostLock.pinWrong);
      expect(wrong.attemptsLeft, HostService.maxTriesPerClient - 1);
      expect(
        host.app.hostService.clients.single.state,
        HostClientState.wrongPin,
      );

      final open = await client.app.hostService.browse(host.id, pin: pin);
      expect(open.isLocked, isFalse);
      expect(open.items.single.name, 'secret.bin');
      // Admitted for as long as it hosts: no PIN needed again.
      expect((await client.app.hostService.browse(host.id)).items, isNotEmpty);

      final arrived = client.app.fileSharingCoordinator.hostBatches.first;
      final answer = await client.app.hostService.download(host.id, [
        open.items.single.itemId,
      ]);
      expect(answer.accepted, isTrue);
      await arrived.timeout(const Duration(seconds: 20));
    });

    test('too many wrong PINs block the phone, even with the right PIN '
        'afterwards', () async {
      final pin = host.app.hostService.pin!;
      final bad = pin == '000000' ? '111111' : '000000';
      HostCatalog? last;
      for (var i = 0; i < HostService.maxTriesPerClient; i++) {
        last = await client.app.hostService.browse(host.id, pin: bad);
      }
      expect(last!.lock, HostLock.tooManyAttempts);
      final after = await client.app.hostService.browse(
        host.id,
        pin: host.app.hostService.pin,
      );
      expect(after.lock, HostLock.tooManyAttempts);
      expect(after.items, isEmpty);
      expect(
        host.app.hostService.clients.single.state,
        HostClientState.blocked,
      );
    });

    test('the beacon says the share is private', () {
      final beacon = DiscoveryBeacon(
        deviceId: Uint8List(16),
        port: 5000,
        supportedTransports: const {TransportType.lan},
        displayName: 'Host',
        hosting: true,
        hostingPrivate: true,
      );
      final decoded = DiscoveryBeacon.fromBytes(beacon.toBytes());
      expect(decoded.hosting, isTrue);
      expect(decoded.hostingPrivate, isTrue);
      expect(decoded.supportedTransports, {TransportType.lan});
      // Public shares and phones not hosting carry no private bit.
      final public = DiscoveryBeacon.fromBytes(
        DiscoveryBeacon(
          deviceId: Uint8List(16),
          port: 5000,
          supportedTransports: const {TransportType.lan},
          displayName: 'Host',
          hostingPrivate: true,
        ).toBytes(),
      );
      expect(public.hostingPrivate, isFalse);
    });
  });

  test('items the host does not share are refused', () async {
    final source = _file(host.dir, 'a.bin', 1000);
    host.app.hostService.startHosting('Share', [
      SelectedDocument(identifier: source.path, name: 'a.bin', sizeBytes: 1000),
    ]);
    final answer = await client.app.hostService.download(host.id, ['ff' * 16]);
    expect(answer.accepted, isFalse);
    expect(answer.reason, HostDeclineReason.unknownItems);
  });

  test('a client is told when the host stops sharing', () async {
    final source = _file(host.dir, 'a.bin', 1000);
    host.app.hostService.startHosting('Share', [
      SelectedDocument(identifier: source.path, name: 'a.bin', sizeBytes: 1000),
    ]);
    await client.app.hostService.browse(host.id);
    final ended = client.app.hostService.hostsEnded.first;
    await host.app.hostService.stopHosting();
    expect(
      (await ended.timeout(const Duration(seconds: 5))).toLowerCase(),
      host.id.toLowerCase(),
    );
    expect(host.app.hostService.isHosting, isFalse);
    // Asking again now gets an honest "not hosting".
    expect((await client.app.hostService.browse(host.id)).hosting, isFalse);
  });
}
