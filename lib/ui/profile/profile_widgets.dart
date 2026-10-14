import 'package:flutter/material.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/ui/card/my_card_page.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// The first profile step from home: just a name, in a bottom sheet.
Future<void> showProfileSetupSheet(
  BuildContext context, {
  required AppContainer container,
}) {
  return showVayuSheet<void>(
    context: context,
    builder: (_) => _ProfileSetupSheet(container: container),
  );
}

class _ProfileSetupSheet extends StatefulWidget {
  final AppContainer container;

  const _ProfileSetupSheet({required this.container});

  @override
  State<_ProfileSetupSheet> createState() => _ProfileSetupSheetState();
}

class _ProfileSetupSheetState extends State<_ProfileSetupSheet> {
  final _name = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      await widget.container.setUpProfile(name);
      navigator.pop();
      showVayuNotice(null, 'Profile saved', tone: VayuNoticeTone.success);
    } catch (e) {
      AppLogger.warning('Profile', 'Saving the profile failed: $e');
      if (mounted) setState(() => _saving = false);
      showVayuNotice(null, friendlyError(e), tone: VayuNoticeTone.problem);
    }
  }

  @override
  Widget build(BuildContext context) {
    return VayuSheet(
      title: 'Set up your profile',
      message: 'Your name goes on your card, so people know who is sharing.',
      content: TextField(
        controller: _name,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: const InputDecoration(labelText: 'Your name'),
      ),
      actions: [
        FilledButton(
          onPressed: _saving || _name.text.trim().isEmpty ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Not now'),
        ),
      ],
    );
  }
}

/// Slim banner at the top of home, inside the page (it pushes content down;
/// nothing floats over other features). Shown only when the profile was
/// skipped and the banner was not closed.
class ProfilePromptBanner extends StatelessWidget {
  final AppContainer container;

  const ProfilePromptBanner({super.key, required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<UserSettings>(
      stream: container.userSettingsStream,
      initialData: container.userSettings,
      builder: (context, snapshot) {
        final settings = snapshot.data ?? container.userSettings;
        final show =
            settings.profileName == null && !settings.profilePromptDismissed;
        return AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !show
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () =>
                          showProfileSetupSheet(context, container: container),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                        child: Row(
                          children: [
                            Icon(
                              Icons.badge_outlined,
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Set up your profile so friends know it\'s you',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => showProfileSetupSheet(
                                context,
                                container: container,
                              ),
                              child: const Text('Set up'),
                            ),
                            IconButton(
                              tooltip: 'Not now',
                              icon: const Icon(Icons.close_rounded, size: 20),
                              onPressed: container.dismissProfilePrompt,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// App-bar button for the profile: initials (or a person icon) inside a
/// ring that fills as the profile is completed. Opens the profile.
class ProfileButton extends StatelessWidget {
  final AppContainer container;

  const ProfileButton({super.key, required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<VayuCard?>(
      stream: container.myCardStream,
      initialData: container.myCard,
      builder: (context, snapshot) {
        final card = snapshot.data ?? container.myCard;
        final progress = ProfileProgress.of(card);
        return IconButton(
          tooltip: 'Profile',
          onPressed: () => MyCardPage.open(context, container),
          icon: SizedBox(
            width: 34,
            height: 34,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (!progress.isComplete)
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: progress.fraction,
                      strokeWidth: 2.5,
                      color: theme.colorScheme.secondary,
                      backgroundColor: theme.colorScheme.outlineVariant,
                    ),
                  ),
                CircleAvatar(
                  radius: 13,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  foregroundColor: theme.colorScheme.onSecondaryContainer,
                  child: card == null
                      ? const Icon(Icons.person_outline_rounded, size: 16)
                      : Text(
                          card.initials,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
