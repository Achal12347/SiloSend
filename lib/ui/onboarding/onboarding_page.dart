import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/identity/device_name_generator.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/widgets/vayu_mark.dart';

/// First-launch introduction in three slides (swipe or tap Continue):
/// what Vayu is, privacy, and setting up a profile (just a name).
///
/// The profile can be skipped; home then shows a small "Set up your profile"
/// banner. Permissions are not asked here, only when they are first needed.
class OnboardingPage extends StatefulWidget {
  final AppContainer container;

  const OnboardingPage({super.key, required this.container});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  static const _pageCount = 3;
  final _pages = PageController();
  int _page = 0;
  bool _finishing = false;

  late final TextEditingController _name = TextEditingController(
    text: widget.container.userSettings.profileName ?? '',
  );

  @override
  void dispose() {
    _pages.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _isLast => _page == _pageCount - 1;

  void _goTo(int page) {
    FocusScope.of(context).unfocus();
    _pages.animateToPage(
      page,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _finish({required bool withProfile}) async {
    if (_finishing) return;
    HapticFeedback.selectionClick();
    setState(() => _finishing = true);
    final container = widget.container;
    try {
      final name = _name.text.trim();
      if (withProfile && name.isNotEmpty) await container.setUpProfile(name);
    } catch (e) {
      // The profile is optional; a failure here must not block the app.
      AppLogger.warning('Onboarding', 'Saving the profile failed: $e');
    }
    await container.completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _name.text.trim();
    final currentPhone = widget.container.identity?.displayName ?? '';
    final phoneName =
        name.isNotEmpty && DeviceNameGenerator.isAutomatic(currentPhone)
        ? DeviceNameGenerator.phoneNameFor(name)
        : currentPhone;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
              child: SizedBox(
                height: 40,
                child: Row(
                  children: [
                    _Dots(count: _pageCount, index: _page),
                    const Spacer(),
                    if (!_isLast)
                      TextButton(
                        onPressed: () => _goTo(_pageCount - 1),
                        child: const Text('Skip'),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  const _Slide(
                    art: VayuMark(size: 112),
                    title: 'Welcome to Vayu',
                    body: 'Share files with phones nearby.\nNo internet, no accounts.',
                  ),
                  _Slide(
                    art: Icon(
                      Icons.lock_outline_rounded,
                      size: 64,
                      color: theme.colorScheme.secondary,
                    ),
                    title: 'Private by design',
                    child: const Column(
                      children: [
                        _Point(
                          icon: Icons.phonelink_rounded,
                          text: 'Files go straight between phones',
                        ),
                        _Point(
                          icon: Icons.enhanced_encryption_outlined,
                          text: 'Encrypted from end to end',
                        ),
                        _Point(
                          icon: Icons.no_accounts_outlined,
                          text: 'No account, no cloud',
                        ),
                      ],
                    ),
                  ),
                  _Slide(
                    art: Icon(
                      Icons.badge_outlined,
                      size: 64,
                      color: theme.colorScheme.secondary,
                    ),
                    title: 'Set up your profile',
                    body: 'Your name goes on your card, so people know who is sharing.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _name,
                          onChanged: (_) => setState(() {}),
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) {
                            if (_name.text.trim().isNotEmpty) {
                              _finish(withProfile: true);
                            }
                          },
                          decoration: const InputDecoration(
                            labelText: 'Your name',
                          ),
                        ),
                        if (phoneName.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Nearby phones will see "$phoneName".',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: _isLast
                  ? Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: FilledButton(
                            onPressed: _finishing || name.isEmpty
                                ? null
                                : () => _finish(withProfile: true),
                            child: const Text('Continue'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _finishing
                              ? null
                              : () => _finish(withProfile: false),
                          child: const Text('Skip for now'),
                        ),
                      ],
                    )
                  : SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton(
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _goTo(_page + 1);
                        },
                        child: Text(_page == 0 ? 'Get started' : 'Continue'),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Slide extends StatelessWidget {
  final Widget art;
  final String title;
  final String? body;
  final Widget? child;

  const _Slide({required this.art, required this.title, this.body, this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 40, 28, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          art,
          const SizedBox(height: 32),
          Text(title, style: theme.textTheme.headlineMedium),
          if (body != null) ...[
            const SizedBox(height: 12),
            Text(
              body!,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (child != null) ...[const SizedBox(height: 28), child!],
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Point({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.secondary),
          const SizedBox(width: 16),
          Expanded(child: Text(text, style: theme.textTheme.titleMedium)),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int index;

  const _Dots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'Step ${index + 1} of $count',
      child: Row(
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              margin: const EdgeInsets.only(right: 6),
              width: i == index ? 22 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == index
                    ? theme.colorScheme.secondary
                    : theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}
