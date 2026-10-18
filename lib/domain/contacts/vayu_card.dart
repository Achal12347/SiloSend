import 'dart:convert';
import 'dart:typed_data';

/// The next thing worth adding to a profile, in the order Vayu asks for it.
enum ProfileStep { name, reach, work }

/// How complete a profile is: name, a way to reach you, what you do.
class ProfileProgress {
  final Set<ProfileStep> done;

  const ProfileProgress(this.done);

  factory ProfileProgress.of(VayuCard? card) {
    bool has(String? v) => v != null && v.trim().isNotEmpty;
    return ProfileProgress({
      if (card != null && has(card.name)) ProfileStep.name,
      if (card != null && (has(card.phone) || has(card.email)))
        ProfileStep.reach,
      if (card != null && (has(card.title) || has(card.company)))
        ProfileStep.work,
    });
  }

  double get fraction => done.length / ProfileStep.values.length;

  bool get isComplete => done.length == ProfileStep.values.length;

  /// The first step not done yet, or null when complete.
  ProfileStep? get next =>
      ProfileStep.values.where((s) => !done.contains(s)).firstOrNull;
}

/// The user's own business card. Kept only on this phone; shared as a
/// standard vCard 3.0 so any contacts app can save it.
class VayuCard {
  /// Largest card served over NFC (the reader accepts up to 8 KB).
  static const int maxVcardBytes = 4 * 1024;

  final String name;
  final String? title;
  final String? company;
  final String? phone;
  final String? email;
  final String? website;
  final String? note;

  /// Index into the card accent palette chosen by the user.
  final int accent;

  const VayuCard({
    required this.name,
    this.title,
    this.company,
    this.phone,
    this.email,
    this.website,
    this.note,
    this.accent = 0,
  });

  /// Initials for the avatar ("Riya Sharma" -> "RS").
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final letters = parts.take(2).map((p) => p.characters.first.toUpperCase());
    final result = letters.join();
    return result.isEmpty ? '?' : result;
  }

  /// "Title · Company", whichever parts exist.
  String? get role {
    final parts = [
      title,
      company,
    ].whereType<String>().where((p) => p.isNotEmpty);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  VayuCard copyWith({
    String? name,
    String? title,
    String? company,
    String? phone,
    String? email,
    String? website,
    String? note,
    int? accent,
  }) => VayuCard(
    name: name ?? this.name,
    title: title ?? this.title,
    company: company ?? this.company,
    phone: phone ?? this.phone,
    email: email ?? this.email,
    website: website ?? this.website,
    note: note ?? this.note,
    accent: accent ?? this.accent,
  );

  /// Standard vCard 3.0 (CRLF line endings, escaped text values).
  Uint8List toVcard() {
    String esc(String v) => v
        .replaceAll('\\', '\\\\')
        .replaceAll('\n', '\\n')
        .replaceAll(',', '\\,')
        .replaceAll(';', '\\;');
    final trimmed = name.trim();
    final parts = trimmed.split(RegExp(r'\s+'));
    final family = parts.length > 1 ? parts.last : '';
    final given = parts.length > 1
        ? parts.sublist(0, parts.length - 1).join(' ')
        : trimmed;
    final lines = <String>[
      'BEGIN:VCARD',
      'VERSION:3.0',
      'FN:${esc(trimmed)}',
      'N:${esc(family)};${esc(given)};;;',
      if (_has(company)) 'ORG:${esc(company!.trim())}',
      if (_has(title)) 'TITLE:${esc(title!.trim())}',
      if (_has(phone)) 'TEL;TYPE=CELL:${phone!.trim()}',
      if (_has(email)) 'EMAIL;TYPE=INTERNET:${email!.trim()}',
      if (_has(website)) 'URL:${_withScheme(website!.trim())}',
      if (_has(note)) 'NOTE:${esc(note!.trim())}',
      // Vayu's card colour, so the receiver shows the card as the sender
      // chose it. Contacts apps ignore X- properties.
      'X-VAYU-STYLE:$accent',
      'END:VCARD',
    ];
    return Uint8List.fromList(utf8.encode('${lines.join('\r\n')}\r\n'));
  }

  static bool _has(String? v) => v != null && v.trim().isNotEmpty;

  // "riya.design" -> "https://riya.design", so contacts apps can open it.
  static String _withScheme(String url) =>
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)
      ? url
      : 'https://$url';

  Map<String, Object?> toJson() => {
    'name': name,
    if (title != null) 'title': title,
    if (company != null) 'company': company,
    if (phone != null) 'phone': phone,
    if (email != null) 'email': email,
    if (website != null) 'website': website,
    if (note != null) 'note': note,
    'accent': accent,
  };

  static VayuCard? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    String? text(String key) {
      final v = raw[key];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    return VayuCard(
      name: name,
      title: text('title'),
      company: text('company'),
      phone: text('phone'),
      email: text('email'),
      website: text('website'),
      note: text('note'),
      accent: raw['accent'] is int ? raw['accent'] as int : 0,
    );
  }
}

extension on String {
  Iterable<String> get characters => runes.map(String.fromCharCode);
}
