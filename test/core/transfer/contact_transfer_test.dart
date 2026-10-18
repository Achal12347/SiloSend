import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

import '../../ui/home/vayu_home_page_test.dart' show MockDiscoveryService;

Future<AppContainer> _container(String name) async {
  final server = LanConnectionServer(requestedPort: 0);
  await server.start();
  final c = AppContainer.standard(
    storage: InMemoryIdentityStorage(
      LocalDeviceIdentity.generate(displayName: name, platform: 'android'),
    ),
    lanServer: server,
    discoveryCoordinator: DiscoveryCoordinator(
      services: [MockDiscoveryService(TransportType.lan)],
    ),
  );
  await c.initialize();
  return c;
}

final _vcard = Uint8List.fromList(
  utf8.encode(
    'BEGIN:VCARD\r\nVERSION:2.1\r\nFN:Riya Sharma\r\nTEL;CELL:+91 98765 43210\r\nEND:VCARD\r\n',
  ),
);

void main() {
  late AppContainer sender;
  late AppContainer receiver;
  late Directory saveDir;
  late DiscoveredPeer receiverPeer;

  setUp(() async {
    sender = await _container('Sender');
    receiver = await _container('Receiver');
    saveDir = Directory.systemTemp.createTempSync('vayu_contacts_');
    final shown = (await receiver.pairingCoordinator.buildLocalPayload())
        .copyWith(lanAddress: '127.0.0.1');
    receiverPeer = await sender.pairingCoordinator.join(shown);
  });

  tearDown(() async {
    await sender.lanServer?.stop();
    await receiver.lanServer?.stop();
    sender.dispose();
    receiver.dispose();
    if (saveDir.existsSync()) saveDir.deleteSync(recursive: true);
  });

  test(
    'a contact arrives as a verified vCard the receiver can preview',
    () async {
      // The receiver is on its Receive screen (offers are only taken there).
      receiver.fileSharingCoordinator.startReceiveSession('00' * 16);
      final offer = receiver.fileSharingCoordinator.incomingRequests.first;
      final sending = await sender.fileSharingCoordinator.sendContactToPeer(
        receiverPeer,
        name: 'Riya Sharma',
        vcard: _vcard,
      );

      final request = await offer.timeout(const Duration(seconds: 5));
      expect(request.metadata.payloadType, PayloadType.contact);
      expect(request.metadata.fileName, 'Riya Sharma.vcf');

      final receiving = await receiver.fileSharingCoordinator
          .acceptIncomingTransfer(request, customSaveDirectory: saveDir.path);
      await Future.wait([sending.done, receiving.done]);
      expect(sending.status, TransferStatus.completed);

      final saved = File('${saveDir.path}/Riya Sharma.vcf');
      final card = ContactCard.tryParse(await saved.readAsBytes());
      expect(card?.displayName, 'Riya Sharma');
      expect(card?.phones, ['+91 98765 43210']);
    },
  );

  test(
    'sending something that is not a contact card is refused locally',
    () async {
      await expectLater(
        sender.fileSharingCoordinator.sendContactToPeer(
          receiverPeer,
          name: 'Bad',
          vcard: Uint8List.fromList(utf8.encode('not a card')),
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );
}
