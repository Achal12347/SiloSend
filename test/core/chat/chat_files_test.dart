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

/// A whole app (real sessions, transfers, storage) on loopback.
class _Phone {
  final String name;
  final Directory dir = Directory.systemTemp.createTempSync('vayu_chatf_');
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

  ChatMessage? last(_Phone other) =>
      app.chatService.conversationWith(other.id)?.lastMessage;

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

SelectedDocument _doc(Directory dir, String name, int size) {
  final random = Random(5);
  final file = File('${dir.path}/$name')
    ..writeAsBytesSync(
      Uint8List.fromList(List.generate(size, (_) => random.nextInt(256))),
    );
  return SelectedDocument(
    identifier: file.path,
    name: name,
    sizeBytes: size,
    mimeType: 'application/octet-stream',
  );
}

void main() {
  late _Phone ana;
  late _Phone bo;

  setUp(() async {
    ana = _Phone('Ana');
    bo = _Phone('Bo');
    await ana.start();
    await bo.start();
    ana.knows(bo);
    bo.knows(ana);
    // An accepted chat both ways, as before sending files in it.
    await ana.app.chatService.send(deviceId: bo.id, peerName: 'Bo', text: 'hi');
    await _until(() => bo.app.chatService.requests.isNotEmpty);
    await bo.app.chatService.send(
      deviceId: ana.id,
      peerName: 'Ana',
      text: 'hello',
    );
    await _until(() => ana.last(bo)?.text == 'hello');
  });

  tearDown(() async {
    await bo.stop();
    await ana.stop();
  });

  test('chat open on the other phone: the file arrives in the chat '
      'without any prompt or Receive screen', () async {
    bo.app.chatService.setVisible(ana.id, true);
    final doc = _doc(ana.dir, 'photo.bin', 200 * 1024 + 11);
    await ana.app.chatService.sendFiles(
      deviceId: bo.id,
      peerName: 'Bo',
      documents: [doc],
    );

    await _until(() => bo.last(ana)?.fileState == ChatFileState.done);
    final received = bo.last(ana)!;
    expect(received.files.single.name, 'photo.bin');
    final path = received.files.single.savedPath!;
    expect(
      File(path).readAsBytesSync(),
      File(doc.identifier).readAsBytesSync(),
    );
    await _until(() => ana.last(bo)?.fileState == ChatFileState.done);
  });

  test('chat not open: the file waits on hold, and arrives once accepted '
      'in the chat', () async {
    final doc = _doc(ana.dir, 'notes.bin', 50 * 1024);
    await ana.app.chatService.sendFiles(
      deviceId: bo.id,
      peerName: 'Bo',
      documents: [doc],
    );
    await _until(() => bo.last(ana)?.isFile ?? false);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // Held: nothing received, nothing asked.
    expect(bo.last(ana)!.fileState, ChatFileState.offered);
    expect(ana.last(bo)!.fileState, ChatFileState.offered);
    expect(Directory('${bo.dir.path}/Downloads').existsSync(), isFalse);

    // Later, back in the chat, the user accepts it.
    await bo.app.chatService.acceptFiles(ana.id, bo.last(ana)!.id);
    await _until(() => bo.last(ana)?.fileState == ChatFileState.done);
    expect(
      File(bo.last(ana)!.files.single.savedPath!).readAsBytesSync(),
      File(doc.identifier).readAsBytesSync(),
    );
  });

  test('declined in the chat: the sender sees it, nothing is saved', () async {
    await ana.app.chatService.sendFiles(
      deviceId: bo.id,
      peerName: 'Bo',
      documents: [_doc(ana.dir, 'no.bin', 1000)],
    );
    await _until(() => bo.last(ana)?.isFile ?? false);
    await bo.app.chatService.declineFiles(ana.id, bo.last(ana)!.id);
    await _until(() => ana.last(bo)?.fileState == ChatFileState.declined);
    expect(bo.last(ana)!.fileState, ChatFileState.declined);
    expect(File('${bo.dir.path}/Downloads/no.bin').existsSync(), isFalse);
  });

  test('a file message keeps its files and state when saved', () {
    final offered = ChatMessage(
      id: 'aa' * 16,
      fromMe: true,
      text: '',
      sentAt: DateTime.fromMillisecondsSinceEpoch(1000),
      state: MessageState.sent,
      files: const [ChatFile(name: 'a.bin', sizeBytes: 3)],
      fileState: ChatFileState.offered,
    );
    final back = ChatMessage.tryFromJson(offered.toJson())!;
    expect(back.files.single.name, 'a.bin');
    expect(back.fileState, ChatFileState.offered);
  });
}
