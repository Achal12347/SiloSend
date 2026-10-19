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
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

import '../../ui/home/vayu_home_page_test.dart' show MockDiscoveryService;

class _Phone {
  final String name;
  final Directory dir = Directory.systemTemp.createTempSync('vayu_stress_');
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

  File file(String name, int size, int seed) {
    final random = Random(seed);
    return File('${dir.path}/$name')..writeAsBytesSync(
      Uint8List.fromList(List.generate(size, (_) => random.nextInt(256))),
    );
  }

  ChatMessage? last(_Phone other) =>
      app.chatService.conversationWith(other.id)?.lastMessage;

  Future<void> stop() async {
    await app.stopDiscoveryAndAdvertising();
    app.dispose();
    await server.stop();
    dir.deleteSync(recursive: true);
  }
}

Future<void> _until(bool Function() condition, {int seconds = 40}) async {
  for (var i = 0; i < seconds * 20 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

void main() {
  test('one phone hosts, sends a chat file and chats at the same time: '
      'everything arrives intact', () async {
    final ana = _Phone('Ana');
    final bo = _Phone('Bo');
    final cy = _Phone('Cy');
    for (final p in [ana, bo, cy]) {
      await p.start();
    }
    try {
      for (final (a, b) in [(ana, bo), (bo, ana), (ana, cy), (cy, ana)]) {
        a.knows(b);
      }
      // Accepted chat Ana <-> Cy, with Cy's chat open (files come at once).
      await ana.app.chatService.send(
        deviceId: cy.id,
        peerName: 'Cy',
        text: 'hi',
      );
      await _until(() => cy.app.chatService.requests.isNotEmpty);
      await cy.app.chatService.send(
        deviceId: ana.id,
        peerName: 'Ana',
        text: 'yo',
      );
      await _until(() => ana.last(cy)?.text == 'yo');
      cy.app.chatService.setVisible(ana.id, true);

      final hosted = ana.file('hosted.bin', 600 * 1024 + 3, 1);
      final chatFile = ana.file('chat.bin', 500 * 1024 + 9, 2);
      ana.app.hostService.startHosting('Share', [
        SelectedDocument(
          identifier: hosted.path,
          name: 'hosted.bin',
          sizeBytes: hosted.lengthSync(),
        ),
      ]);
      final catalog = await bo.app.hostService.browse(ana.id);

      // All at once.
      await Future.wait([
        bo.app.hostService.download(ana.id, [catalog.items.single.itemId]),
        ana.app.chatService.sendFiles(
          deviceId: cy.id,
          peerName: 'Cy',
          documents: [
            SelectedDocument(
              identifier: chatFile.path,
              name: 'chat.bin',
              sizeBytes: chatFile.lengthSync(),
            ),
          ],
        ),
        for (var i = 0; i < 10; i++) ...[
          ana.app.chatService.send(
            deviceId: cy.id,
            peerName: 'Cy',
            text: 'a$i',
          ),
          cy.app.chatService.send(
            deviceId: ana.id,
            peerName: 'Ana',
            text: 'c$i',
          ),
        ],
      ]);

      final fromHost = File('${bo.dir.path}/Downloads/hosted.bin');
      await _until(
        () =>
            fromHost.existsSync() &&
            fromHost.lengthSync() == hosted.lengthSync(),
      );
      await _until(
        () =>
            cy.app.chatService
                .conversationWith(ana.id)!
                .messages
                .where((m) => m.isFile)
                .single
                .fileState ==
            ChatFileState.done,
      );
      final received = cy.app.chatService
          .conversationWith(ana.id)!
          .messages
          .where((m) => m.isFile)
          .single;
      expect(
        File(received.files.single.savedPath!).readAsBytesSync(),
        chatFile.readAsBytesSync(),
      );
      // Give the host's own file write a moment, then compare it too.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fromHost.readAsBytesSync(), hosted.readAsBytesSync());

      // Every text arrived once, on both sides.
      await _until(() {
        final texts = cy.app.chatService
            .conversationWith(ana.id)!
            .messages
            .where((m) => !m.fromMe)
            .map((m) => m.text)
            .toSet();
        return {for (var i = 0; i < 10; i++) 'a$i'}.every(texts.contains);
      });
      await _until(() {
        final texts = ana.app.chatService
            .conversationWith(cy.id)!
            .messages
            .where((m) => !m.fromMe)
            .map((m) => m.text)
            .toList();
        return {for (var i = 0; i < 10; i++) 'c$i'}.every(texts.contains) &&
            texts.length == texts.toSet().length;
      });
    } finally {
      for (final p in [ana, bo, cy]) {
        await p.stop();
      }
    }
  });
}
