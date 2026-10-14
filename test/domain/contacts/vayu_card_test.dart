import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contacts/my_card_store.dart';
import 'package:vayu/core/pairing/nfc_pairing_service.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/platform/system_platform_service.dart';

const _full = VayuCard(
  name: 'Riya Sharma',
  title: 'Product Designer',
  company: 'Acme, Inc.',
  phone: '+91 98765 43210',
  email: 'riya@example.com',
  website: 'https://riya.design',
  note: 'Met at the meetup; say hi!',
  accent: 2,
);

class _FakeNfc implements NfcPlatformAdapter {
  void Function(Uint8List)? onTag;
  Uint8List? served;

  @override
  Future<bool> isNfcAvailable() async => true;
  @override
  Future<bool> isNfcEnabled() async => true;
  @override
  Future<void> startListening({
    required void Function(Uint8List ndefBytes) onTagDiscovered,
  }) async => onTag = onTagDiscovered;
  @override
  Future<void> stopListening() async => onTag = null;
  @override
  Future<void> writeNdef(Uint8List ndefBytes) async => served = ndefBytes;
  @override
  Future<void> stopServing() async => served = null;
}

void main() {
  test('the vCard is standard and reads back through the contact parser', () {
    final bytes = _full.toVcard();
    final text = utf8.decode(bytes);
    expect(text, startsWith('BEGIN:VCARD\r\nVERSION:3.0\r\n'));
    expect(text, contains('N:Sharma;Riya;;;'));
    // Commas and semicolons in values are escaped.
    expect(text, contains(r'ORG:Acme\, Inc.'));
    expect(text, contains(r'NOTE:Met at the meetup\; say hi!'));

    final parsed = ContactCard.tryParse(bytes)!;
    expect(parsed.displayName, 'Riya Sharma');
    expect(parsed.organization, 'Acme, Inc.');
    expect(parsed.title, 'Product Designer');
    expect(parsed.phones, ['+91 98765 43210']);
    expect(parsed.emails, ['riya@example.com']);
    expect(parsed.website, 'https://riya.design');
  });

  test('a name-only card is still a valid contact', () {
    const card = VayuCard(name: 'Sam');
    final parsed = ContactCard.tryParse(card.toVcard())!;
    expect(parsed.displayName, 'Sam');
    expect(card.initials, 'S');
    expect(card.role, isNull);
    expect(_full.initials, 'RS');
    expect(_full.role, 'Product Designer · Acme, Inc.');
  });

  test('a full card fits the NFC limit', () {
    expect(_full.toVcard().length, lessThan(VayuCard.maxVcardBytes));
  });

  test('the card is saved and loaded unchanged', () async {
    final store = InMemoryMyCardStore();
    await store.save(_full);
    final back = VayuCard.tryFromJson(
      jsonDecode(jsonEncode((await store.load())!.toJson())),
    )!;
    expect(back.toJson(), _full.toJson());
    expect(VayuCard.tryFromJson({'name': '  '}), isNull);
  });

  group('NFC tap', () {
    late _FakeNfc nfc;
    late NfcPairingService service;

    setUp(() {
      nfc = _FakeNfc();
      service = NfcPairingService(
        platformService: SystemPlatformService(),
        platformAdapter: nfc,
      );
    });

    tearDown(() => service.dispose());

    test('sharing a card serves its vCard until stopped', () async {
      final result = await service.shareCard(_full.toVcard());
      expect(result.isSuccess, isTrue);
      expect(nfc.served, _full.toVcard());
      await service.stopSharing();
      expect(nfc.served, isNull);
    });

    test('a tapped card arrives as a card, not as a pairing code', () async {
      final cards = <Uint8List>[];
      final pairings = <PairingPayload>[];
      service.onCardReceived.listen(cards.add);
      service.onPayloadReceived.listen(pairings.add);
      await service.startReading();

      nfc.onTag!(_full.toVcard());
      await Future<void>.delayed(Duration.zero);

      expect(cards, hasLength(1));
      expect(ContactCard.tryParse(cards.single)!.displayName, 'Riya Sharma');
      expect(pairings, isEmpty);
    });
  });
}
