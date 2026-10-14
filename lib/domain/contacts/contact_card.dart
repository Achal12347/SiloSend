import 'dart:convert';
import 'dart:typed_data';

/// A received or outgoing contact, carried as a standard vCard (RFC 6350 / 2.1).
///
/// Vayu never edits the card; it only validates it and extracts a preview so
/// the receiver can decide whether to save it. Saving goes through the phone's
/// contacts app with the original card, so no field is lost or invented.
class ContactCard {
  /// Contacts larger than this are refused before they are accepted.
  static const int maxBytes = 1024 * 1024;

  final String displayName;
  final List<String> phones;
  final List<String> emails;
  final String? organization;
  final String? title;
  final String? website;
  final String? note;
  final Uint8List vcard;

  const ContactCard({
    required this.displayName,
    required this.phones,
    required this.emails,
    required this.vcard,
    this.organization,
    this.title,
    this.website,
    this.note,
  });

  /// Parses and validates [bytes]; returns null when it is not a vCard.
  static ContactCard? tryParse(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) return null;
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return null;
    }
    final lines = _unfold(text);
    final begin = lines.indexWhere(
      (l) => l.trim().toUpperCase() == 'BEGIN:VCARD',
    );
    final end = lines.lastIndexWhere(
      (l) => l.trim().toUpperCase() == 'END:VCARD',
    );
    if (begin < 0 || end <= begin) return null;

    String? fn;
    String? n;
    String? org;
    String? title;
    String? url;
    String? note;
    final phones = <String>[];
    final emails = <String>[];
    for (final line in lines.sublist(begin + 1, end)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final property = line.substring(0, colon).split(';').first.toUpperCase();
      final value = _unescape(line.substring(colon + 1).trim());
      if (value.isEmpty) continue;
      switch (property.split('.').last) {
        case 'FN':
          fn ??= value;
        case 'N':
          n ??= value
              .split(';')
              .where((p) => p.isNotEmpty)
              .toList()
              .reversed
              .join(' ');
        case 'TEL':
          phones.add(
            value.replaceFirst(RegExp(r'^tel:', caseSensitive: false), ''),
          );
        case 'EMAIL':
          emails.add(value);
        case 'ORG':
          org ??= value.split(';').first;
        case 'TITLE':
          title ??= value;
        case 'URL':
          url ??= value;
        case 'NOTE':
          note ??= value;
      }
    }
    final name = (fn ?? n ?? '').trim();
    if (name.isEmpty && phones.isEmpty && emails.isEmpty) return null;
    return ContactCard(
      displayName: name.isEmpty ? (phones.firstOrNull ?? emails.first) : name,
      phones: phones,
      emails: emails,
      organization: org,
      title: title,
      website: url,
      note: note,
      vcard: bytes,
    );
  }

  /// Safe file name for the card, derived from the contact's name.
  static String fileNameFor(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '')
        .trim();
    final base = cleaned.isEmpty ? 'Contact' : cleaned;
    return '${base.length > 60 ? base.substring(0, 60) : base}.vcf';
  }

  // vCard lines may be folded: a continuation starts with a space or tab.
  static List<String> _unfold(String text) {
    final out = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      if ((raw.startsWith(' ') || raw.startsWith('\t')) && out.isNotEmpty) {
        out[out.length - 1] += raw.substring(1);
      } else {
        out.add(raw);
      }
    }
    return out;
  }

  static String _unescape(String value) => value
      .replaceAll(r'\n', ' ')
      .replaceAll(r'\N', ' ')
      .replaceAll(r'\,', ',')
      .replaceAll(r'\;', ';')
      .replaceAll(r'\\', r'\');
}
