import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/domain/contacts/contact_card.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  test(
    'parses name, organization, phones and emails from an Android vCard',
    () {
      final card = ContactCard.tryParse(
        _bytes(
          'BEGIN:VCARD\r\nVERSION:2.1\r\nN:Sharma;Riya;;;\r\nFN:Riya Sharma\r\n'
          'TEL;CELL:+91 98765 43210\r\nTEL;WORK:080 1234\r\n'
          'EMAIL;HOME:riya@example.com\r\nORG:Achyrio;Design\r\nEND:VCARD\r\n',
        ),
      )!;
      expect(card.displayName, 'Riya Sharma');
      expect(card.phones, ['+91 98765 43210', '080 1234']);
      expect(card.emails, ['riya@example.com']);
      expect(card.organization, 'Achyrio');
    },
  );

  test('unfolds continuation lines and unescapes values', () {
    final card = ContactCard.tryParse(
      _bytes(
        'BEGIN:VCARD\nVERSION:4.0\nFN:Dev\n  Patel\\, Jr.\nTEL:tel:+1555\nEND:VCARD\n',
      ),
    )!;
    expect(card.displayName, 'Dev Patel, Jr.');
    expect(card.phones, ['+1555']);
  });

  test('falls back to the structured name when FN is missing', () {
    final card = ContactCard.tryParse(
      _bytes('BEGIN:VCARD\nVERSION:3.0\nN:Rao;Anil;;;\nEND:VCARD'),
    )!;
    expect(card.displayName, 'Anil Rao');
  });

  test('rejects data that is not a contact card', () {
    expect(ContactCard.tryParse(_bytes('hello')), isNull);
    expect(ContactCard.tryParse(_bytes('BEGIN:VCARD\nEND:VCARD')), isNull);
    expect(
      ContactCard.tryParse(Uint8List.fromList([0xff, 0xfe, 0x00])),
      isNull,
    );
    expect(ContactCard.tryParse(Uint8List(ContactCard.maxBytes + 1)), isNull);
  });

  test('derives a safe file name', () {
    expect(
      ContactCard.fileNameFor('Riya/Sharma: *Work*'),
      'RiyaSharma Work.vcf',
    );
    expect(ContactCard.fileNameFor('   '), 'Contact.vcf');
  });
}
