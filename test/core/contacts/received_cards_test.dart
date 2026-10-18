import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/contacts/received_cards.dart';

Uint8List _vcard(String name, {String org = 'Achyrio'}) => Uint8List.fromList(
  utf8.encode(
    'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:$name\r\nORG:$org\r\nTEL:+91 98765 43210\r\nEND:VCARD\r\n',
  ),
);

void main() {
  late Directory dir;
  late File index;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vayu_cards_test_');
    index = File('${dir.path}/received_cards.json');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ReceivedCards store() => ReceivedCards(
    storage: FileReceivedCardsStorage(index),
    directory: () async => '${dir.path}/cards',
  );

  test('a tapped card is kept with its file and survives a restart', () async {
    final cards = store();
    await cards.load();
    final card = await cards.addBytes(_vcard('Riya Sen'), via: ReceivedVia.tap);

    expect(card, isNotNull);
    expect(card!.name, 'Riya Sen');
    expect(card.organization, 'Achyrio');
    expect(File(card.path).readAsBytesSync(), _vcard('Riya Sen'));

    final reloaded = store();
    await reloaded.load();
    expect(reloaded.all.single.name, 'Riya Sen');
    expect((await reloaded.read(reloaded.all.single))?.displayName, 'Riya Sen');
  });

  test('the same tap read twice is stored once', () async {
    final cards = store();
    await cards.load();
    await cards.addBytes(_vcard('Riya Sen'), via: ReceivedVia.tap);
    await cards.addBytes(_vcard('Riya Sen'), via: ReceivedVia.tap);
    expect(cards.all, hasLength(1));

    // A changed card is a new one.
    await cards.addBytes(
      _vcard('Riya Sen', org: 'Elsewhere'),
      via: ReceivedVia.tap,
    );
    expect(cards.all, hasLength(2));
    expect(cards.all.first.organization, 'Elsewhere');
  });

  test('cards received from a nearby phone are recorded by path', () async {
    final cards = store();
    await cards.load();
    final file = File('${dir.path}/from_nearby.vcf')
      ..writeAsBytesSync(_vcard('Arjun'));
    final card = await cards.addFile(
      file.path,
      via: ReceivedVia.nearby,
      fromName: 'Arjun\'s phone',
    );
    expect(card?.fromName, 'Arjun\'s phone');
    expect(cards.all.single.via, ReceivedVia.nearby);
  });

  test('entries whose file is gone are dropped on load', () async {
    final cards = store();
    await cards.load();
    final a = await cards.addBytes(_vcard('Gone'), via: ReceivedVia.tap);
    await cards.addBytes(_vcard('Kept'), via: ReceivedVia.tap);
    File(a!.path).deleteSync();

    final reloaded = store();
    await reloaded.load();
    expect(reloaded.all.map((c) => c.name), ['Kept']);
  });

  test('delete removes the card and its file', () async {
    final cards = store();
    await cards.load();
    final card = await cards.addBytes(_vcard('Riya'), via: ReceivedVia.tap);
    await cards.remove(card!.id);
    expect(cards.all, isEmpty);
    expect(File(card.path).existsSync(), isFalse);
  });

  test('not a card: nothing stored; a damaged index loads empty', () async {
    final cards = store();
    await cards.load();
    expect(
      await cards.addBytes(
        Uint8List.fromList(utf8.encode('hello')),
        via: ReceivedVia.tap,
      ),
      isNull,
    );
    index.writeAsStringSync('{not json');
    final reloaded = store();
    await reloaded.load();
    expect(reloaded.all, isEmpty);
  });
}
