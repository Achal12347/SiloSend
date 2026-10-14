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
    );
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
          decoration: BoxDecoration(
            gradient: VayuCardColors.of(face.accent),
            borderRadius: BorderRadius.circular(24),
            // A faint edge keeps a dark card distinct on a dark screen.
            border: Border.all(
              color: VayuCardColors.onCard.withValues(alpha: 0.08),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 28,
                spreadRadius: -8,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: VayuCardColors.onCard.withValues(
                      alpha: 0.16,
                    ),
                    child: Text(
                      face.initials,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: VayuCardColors.onCard,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.air_rounded,
                    color: VayuCardColors.onCardMuted.withValues(alpha: 0.7),
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
                  color: VayuCardColors.onCard,
                ),
              ),
              if (face.role != null) ...[
                const SizedBox(height: 2),
                Text(
                  face.role!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: VayuCardColors.onCardMuted,
                  ),
                ),
              ],
              if (rows.isNotEmpty) const SizedBox(height: 12),
              for (final (icon, text) in rows.take(3))
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    children: [
                      Icon(icon, size: 14, color: VayuCardColors.onCardMuted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: VayuCardColors.onCard,
                          ),
                        ),
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
