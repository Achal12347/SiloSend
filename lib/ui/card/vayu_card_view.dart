import 'package:flutter/material.dart';

import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';

/// What a card shows, from either the user's own card or a received vCard.
class CardFace {
  final String name;
  final String? role;
  final String? phone;
  final String? email;
  final String? website;
  final int accent;

  const CardFace({
    required this.name,
    this.role,
    this.phone,
    this.email,
    this.website,
    this.accent = 0,
  });

  factory CardFace.fromCard(VayuCard card) => CardFace(
    name: card.name,
    role: card.role,
    phone: card.phone,
    email: card.email,
    website: card.website,
    accent: card.accent,
  );

  factory CardFace.fromContact(ContactCard contact) {
    final role = [
      contact.title,
      contact.organization,
    ].whereType<String>().where((p) => p.isNotEmpty).join(' · ');
    return CardFace(
      name: contact.displayName,
      role: role.isEmpty ? null : role,
      phone: contact.phones.firstOrNull,
      email: contact.emails.firstOrNull,
      website: contact.website,
      accent: contact.style ?? 0,
    );
  }

  /// Links for the phone, email and website lines (dialer, new email,
  /// browser), or null for a line with no usable value.
  Uri? get phoneUri {
    final digits = phone?.replaceAll(RegExp(r'[^0-9+]'), '') ?? '';
    return digits.length < 3 ? null : Uri(scheme: 'tel', path: digits);
  }

  Uri? get emailUri {
    final value = email?.trim() ?? '';
    return value.contains('@') ? Uri(scheme: 'mailto', path: value) : null;
  }

  Uri? get websiteUri {
    final value = website?.trim() ?? '';
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(
      RegExp(r'^https?://', caseSensitive: false).hasMatch(value)
          ? value
          : 'https://$value',
    );
    return uri != null && uri.host.isNotEmpty ? uri : null;
  }

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final letters = parts
        .take(2)
        .map((p) => String.fromCharCode(p.runes.first).toUpperCase());
    final result = letters.join();
    return result.isEmpty ? '?' : result;
  }
}

/// A business card in the shape of a real one (about 1.6 : 1).
class VayuCardView extends StatelessWidget {
  final CardFace face;

  const VayuCardView({super.key, required this.face});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = VayuCardColors.of(face.accent);
    final rows = <(IconData, String)>[
      if (face.phone != null) (Icons.call_outlined, face.phone!),
      if (face.email != null) (Icons.mail_outline_rounded, face.email!),
      if (face.website != null) (Icons.language_rounded, face.website!),
    ];

    return Semantics(
      label: 'Card for ${face.name}',
      child: AspectRatio(
        aspectRatio: 1.6,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: style.gradient,
            borderRadius: BorderRadius.circular(24),
            // A faint edge keeps a dark card distinct on a dark screen.
            border: Border.all(color: style.onCard.withValues(alpha: 0.10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 28,
                spreadRadius: -8,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Soft light in the top corner gives depth without loud colour.
              Positioned(
                right: -70,
                top: -90,
                child: IgnorePointer(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          style.glow.withValues(alpha: 0.30),
                          style.glow.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 22,
                          backgroundColor: style.onCard.withValues(alpha: 0.16),
                          child: Text(
                            face.initials,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: style.onCard,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          Icons.air_rounded,
                          color: style.onCardMuted.withValues(alpha: 0.8),
                          size: 22,
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      face.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: style.onCard,
                      ),
                    ),
                    if (face.role != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        face.role!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: style.onCardMuted,
                        ),
                      ),
                    ],
                    if (rows.isNotEmpty) const SizedBox(height: 12),
                    for (final (icon, text) in rows.take(3))
                      _CardLine(
                        icon: icon,
                        text: text,
                        style: style,
                        textStyle: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One contact line on the card.
class _CardLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final CardStyle style;
  final TextStyle? textStyle;

  const _CardLine({
    required this.icon,
    required this.text,
    required this.style,
    required this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: style.onCardMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle?.copyWith(color: style.onCard),
            ),
          ),
        ],
      ),
    );
  }
}
