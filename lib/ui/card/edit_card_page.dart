import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/contacts/country_codes.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/ui/card/country_picker_sheet.dart';
import 'package:vayu/ui/card/vayu_card_view.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Create or edit the user's card, with a live preview. Only the name is
/// required; everything entered stays on this phone until the user shares it.
class EditCardPage extends StatefulWidget {
  final AppContainer container;

  const EditCardPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EditCardPage(container: container)),
      );

  @override
  State<EditCardPage> createState() => _EditCardPageState();
}

class _EditCardPageState extends State<EditCardPage> {
  final _form = GlobalKey<FormState>();
  late final VayuCard? _existing = widget.container.myCard;
  late final _name = TextEditingController(
    text: _existing?.name ?? widget.container.userSettings.profileName ?? '',
  );
  late final _title = TextEditingController(text: _existing?.title);
  late final _company = TextEditingController(text: _existing?.company);
  // The phone is stored with its country code ("+91 98765 43210"); the
  // editor shows the code as a picker and the rest as the number.
  late final (CountryDial?, String) _storedPhone = splitPhone(
    _existing?.phone ?? '',
    preferredIso: _regionIso,
  );
  late CountryDial _country =
      _storedPhone.$1 ?? countryForIso(_regionIso) ?? countryForIso('IN')!;
  late final _phone = TextEditingController(text: _storedPhone.$2);

  /// This phone's region from its language settings, e.g. "IN".
  static String? get _regionIso =>
      WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  late final _email = TextEditingController(text: _existing?.email);
  late final _website = TextEditingController(text: _existing?.website);
  late final _note = TextEditingController(text: _existing?.note);
  late int _accent = _existing?.accent ?? 0;
  bool _saving = false;

  List<TextEditingController> get _all => [
    _name,
    _title,
    _company,
    _phone,
    _email,
    _website,
    _note,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  String? _text(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
  }

  VayuCard get _draft => VayuCard(
    name: _name.text.trim().isEmpty ? 'Your name' : _name.text.trim(),
    title: _text(_title),
    company: _text(_company),
    phone: _phoneValue,
    email: _text(_email),
    website: _text(_website),
    note: _text(_note),
    accent: _accent,
  );

  /// The number as stored. A number typed with its own "+code" keeps that
  /// code (pasted numbers); otherwise the picker's code is put in front.
  String? get _phoneValue {
    final typed = _phone.text.trim();
    if (typed.isEmpty) return null;
    if (typed.startsWith('+')) {
      final (country, rest) = splitPhone(typed, preferredIso: _country.iso);
      return country == null ? typed : joinPhone(country, rest);
    }
    return joinPhone(_country, typed);
  }

  Future<void> _pickCountry() async {
    final picked = await showCountryPicker(context, current: _country);
    if (picked != null && mounted) setState(() => _country = picked);
  }

  Future<void> _save() async {
    if (_form.currentState?.validate() != true) return;
    final card = _draft;
    if (card.toVcard().length > VayuCard.maxVcardBytes) {
      showVayuNotice(
        context,
        'That card is too long. Shorten the note.',
        tone: VayuNoticeTone.problem,
      );
      return;
    }
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.container.saveMyCard(card);
      navigator.pop();
    } catch (e) {
      showVayuNotice(
        null,
        friendlyError(e),
        tone: VayuNoticeTone.problem,
        messenger: messenger,
      );
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboard,
    TextCapitalization caps = TextCapitalization.none,
    String? Function(String?)? validator,
    int maxLines = 1,
    int? maxLength,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboard,
        textCapitalization: caps,
        maxLines: maxLines,
        maxLength: maxLength,
        onChanged: (_) => setState(() {}),
        validator: validator,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? 'Create your card' : 'Edit card'),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              VayuCardView(face: CardFace.fromCard(_draft)),
              const SizedBox(height: 16),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var i = 0; i < VayuCardColors.styles.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Semantics(
                          button: true,
                          selected: i == _accent,
                          label: '${VayuCardColors.styles[i].name} colour',
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => setState(() => _accent = i),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: VayuCardColors.styles[i].gradient,
                                border: Border.all(
                                  width: 3,
                                  color: i == _accent
                                      ? theme.colorScheme.secondary
                                      : Colors.transparent,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _field(
                _name,
                'Name',
                caps: TextCapitalization.words,
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? 'Enter your name' : null,
              ),
              _field(_title, 'Job title', caps: TextCapitalization.words),
              _field(_company, 'Company', caps: TextCapitalization.words),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 56,
                      child: OutlinedButton(
                        onPressed: _pickCountry,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        child: Semantics(
                          label: 'Country code ${_country.plusCode}',
                          child: Text(
                            '${_country.flag} ${_country.plusCode}',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        onChanged: (value) => setState(() {
                          final typed = value.trim();
                          if (typed.startsWith('+')) {
                            final country = splitPhone(
                              typed,
                              preferredIso: _country.iso,
                            ).$1;
                            if (country != null) _country = country;
                          }
                        }),
                        validator: (v) {
                          final digits = (v ?? '').replaceAll(
                            RegExp(r'[^0-9]'),
                            '',
                          );
                          if (digits.isEmpty) return null;
                          if (digits.length < 5 || digits.length > 14) {
                            return 'Check the number';
                          }
                          return null;
                        },
                        decoration: const InputDecoration(labelText: 'Phone'),
                      ),
                    ),
                  ],
                ),
              ),
              _field(
                _email,
                'Email',
                keyboard: TextInputType.emailAddress,
                validator: (v) {
                  final value = v?.trim() ?? '';
                  if (value.isEmpty) return null;
                  final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                      .hasMatch(value);
                  return ok ? null : 'Check the email';
                },
              ),
              _field(_website, 'Website', keyboard: TextInputType.url),
              _field(
                _note,
                'Note',
                caps: TextCapitalization.sentences,
                maxLines: 3,
                maxLength: 300,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 54,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save card'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
