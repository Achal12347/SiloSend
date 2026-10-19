import 'dart:convert';
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
import 'package:vayu/core/mesh/relay_service.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/chat/chat_models.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/mesh/relay_payloads.dart';

import '../../ui/home/vayu_home_page_test.dart' show MockDiscoveryService;

/// A whole app (real sessions, transfers, storage) on loopback.
class _Phone {
  final String name;
  final Directory dir = Directory.systemTemp.createTempSync('vayu_mesh_');
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

  /// Remembers [other] but with no way to reach it directly (out of range).
  void outOfRange(_Phone other) => app.fileSharingCoordinator.rememberPeer(
    DiscoveredPeer(
      deviceId: other.id,
      displayName: other.name,
      transportType: TransportType.relay,
      availableTransports: const {},
      rssi: 0,
      lastSeen: DateTime.now(),
    ),
  );

  Future<void> chat(_Phone other, String text) => app.chatService.send(
    deviceId: other.id,
    peerName: other.name,
    text: text,
  );

  ChatMessage? last(_Phone other) =>
      app.chatService.conversationWith(other.id)?.lastMessage;

  Future<void> dropSessionsWith(_Phone other) async {
    for (final s in app.secureSessionManager.activeSessions.toList()) {
      if (s.remoteDeviceId.toLowerCase() == other.id.toLowerCase()) {
        await s.connectionSession.close(reason: 'test');
      }
    }
  }

  Future<void> stop() async {
    await app.stopDiscoveryAndAdvertising();
    app.dispose();
    await server.stop();
    dir.deleteSync(recursive: true);
  }
}

Future<void> _until(bool Function() condition, {int seconds = 20}) async {
  for (var i = 0; i < seconds * 20 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  late _Phone ana;
  late _Phone bo;
  late _Phone cy;

  setUp(() async {
    ana = _Phone('Ana');
    bo = _Phone('Bo');
    cy = _Phone('Cy');
    for (final p in [ana, bo, cy]) {
      await p.start();
    }
    // Ana and Cy met directly once (their keys are pinned), then moved
    // apart: Ana can no longer reach Cy, only Bo, who is near both.
    ana.knows(cy);
    await ana.chat(cy, 'hi');
    await _until(() => cy.last(ana)?.text == 'hi');
    await ana.dropSessionsWith(cy);
    await cy.dropSessionsWith(ana);
    await _until(
      () => ana.app.secureSessionManager.getSessionForPeer(cy.id) == null,
    );
    ana.outOfRange(cy);

    ana.knows(bo);
    bo.knows(ana);
    bo.knows(cy);
    cy.knows(bo);
    await ana.chat(bo, 'hello Bo');
    await bo.chat(cy, 'hello Cy');
    await _until(() => cy.last(bo)?.text == 'hello Cy');
  });

  tearDown(() async {
    for (final p in [ana, bo, cy]) {
      await p.stop();
    }
  });

  test('with relaying on, a message and a file reach the phone out of range '
      'through the one in between, which forwards no plaintext', () async {
    await bo.app.setRelayEnabled(true);
    final forwarded = <int>[];
    bo.app.relayService!.debugOnForward = forwarded.addAll;

    const secret = 'meet at the north gate at nine';
    await ana.chat(cy, secret);
    await _until(() => cy.last(ana)?.text == secret);
    final session = ana.app.secureSessionManager.getSessionForPeer(cy.id)!;
    expect(session.connectionSession.connection.type, TransportType.relay);
    expect(bo.app.relayService!.relayingCount, 1);

    // A file whose content is easy to look for in what Bo forwarded.
    final marker = utf8.encode('VAYU-PLAINTEXT-MARKER-0123456789');
    final random = Random(9);
    final bytes = Uint8List.fromList([
      for (var i = 0; i < 40; i++) ...marker,
      ...List.generate(150 * 1024, (_) => random.nextInt(256)),
    ]);
    final file = File('${ana.dir.path}/plan.bin')..writeAsBytesSync(bytes);
    await ana.app.chatService.sendFiles(
      deviceId: cy.id,
      peerName: 'Cy',
      documents: [
        SelectedDocument(
          identifier: file.path,
          name: 'plan.bin',
          sizeBytes: bytes.length,
        ),
      ],
    );
    await _until(() => cy.last(ana)?.isFile ?? false);
    await cy.app.chatService.acceptFiles(ana.id, cy.last(ana)!.id);
    await _until(
      () => cy.last(ana)?.fileState == ChatFileState.done,
      seconds: 40,
    );
    expect(
      File(cy.last(ana)!.files.single.savedPath!).readAsBytesSync(),
      bytes,
    );

    // Bo carried all of it, and none of it readable.
    expect(forwarded.length, greaterThan(bytes.length));
    expect(_contains(forwarded, marker), isFalse);
    expect(_contains(forwarded, utf8.encode(secret)), isFalse);
  });

  test('with relaying off (the default) nothing is relayed', () async {
    expect(bo.app.userSettings.relayEnabled, isFalse);
    await expectLater(ana.chat(cy, 'anyone?'), throwsA(anything));
    expect(ana.last(cy)!.state, MessageState.failed);
    expect(bo.app.relayService!.relayingCount, 0);
    expect(cy.last(ana)?.text, 'hi');
  });

  test('a phone never met directly cannot be reached through others', () async {
    await bo.app.setRelayEnabled(true);
    final stranger = LocalDeviceIdentity.generate(
      displayName: 'Stranger',
      platform: 'android',
    );
    await expectLater(
      ana.app.relayService!.open(stranger.idHex),
      throwsA(
        isA<MeshUnavailableException>().having(
          (e) => e.refusal,
          'refusal',
          RelayRefusal.notKnown,
        ),
      ),
    );
  });

  test(
    'when the relay loses the far phone, the relayed session ends',
    () async {
      await bo.app.setRelayEnabled(true);
      await ana.chat(cy, 'still there?');
      await _until(() => cy.last(ana)?.text == 'still there?');
      expect(ana.app.secureSessionManager.getSessionForPeer(cy.id), isNotNull);

      await bo.dropSessionsWith(cy);
      await _until(
        () => ana.app.secureSessionManager.getSessionForPeer(cy.id) == null,
      );
      await _until(() => bo.app.relayService!.relayingCount == 0);
    },
  );

  test('two phones in between: Ana → Bo → Dee → Cy', () async {
    final dee = _Phone('Dee');
    await dee.start();
    try {
      // Bo can no longer reach Cy; Dee is near both Bo and Cy.
      await bo.dropSessionsWith(cy);
      await cy.dropSessionsWith(bo);
      bo.outOfRange(cy);
      bo.knows(dee);
      dee.knows(bo);
      dee.knows(cy);
      await bo.chat(dee, 'hi Dee');
      await dee.chat(cy, 'hi Cy');
      await _until(() => cy.last(dee)?.text == 'hi Cy');
      await bo.app.setRelayEnabled(true);
      await dee.app.setRelayEnabled(true);

      await ana.chat(cy, 'over two relays');
      await _until(() => cy.last(ana)?.text == 'over two relays');
      expect(bo.app.relayService!.relayingCount, 1);
      expect(dee.app.relayService!.relayingCount, 1);
    } finally {
      await dee.stop();
    }
  });

  test('reach answers list salted hashes, never device IDs', () {
    const salt = 'ab12ab12ab12ab12ab12ab12ab12ab12';
    final hash = ReachAnswer.hashOf(salt, cy.id);
    expect(hash, hasLength(16));
    expect(hash, isNot(contains(cy.id.substring(0, 8))));
    expect(ReachAnswer.hashOf('cd' * 16, cy.id), isNot(hash));
    final answer = ReachAnswer.fromBytes(
      ReachAnswer(queryId: salt, relaying: true, hashes: [hash]).toBytes(),
    );
    expect(answer.hashes.single, hash);
  });
}
