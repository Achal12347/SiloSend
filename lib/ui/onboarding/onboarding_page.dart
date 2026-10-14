import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/widgets/vayu_mark.dart';

/// First-launch introduction: welcome, your name, privacy, nearby access.
///
/// Every step except the last can be skipped; nothing here is required to
/// use the app. Finishing (or skipping to the end) saves the answers and
/// records completion, after which the app shows home.
class OnboardingPage extends StatefulWidget {
  final AppContainer container;

  const OnboardingPage({super.key, required this.container});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  static const _pageCount = 4;
  final _pages = PageController();
  int _page = 0;
  bool _finishing = false;

  late final TextEditingController _name = TextEditingController(
    text: widget.container.userSettings.profileName ?? '',
  );
  late final TextEditingController _device = TextEditingController(
    text: widget.container.identity?.displayName ?? '',
  );

  // Until the user edits the device name, it follows "<First name>'s phone".
  bool _deviceEdited = false;

  @override
  void dispose() {
    _pages.dispose();
    _name.dispose();
    _device.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    if (_deviceEdited) return;
    final first = value.trim().split(RegExp(r'\s+')).first;
    if (first.isEmpty) return;
    final suggestion = "$first's phone";
    _device.value = TextEditingValue(
      text: suggestion.length > 32 ? suggestion.substring(0, 32) : suggestion,
    );
  }

  void _next() {
    HapticFeedback.selectionClick();
    FocusScope.of(context).unfocus();
    if (_page < _pageCount - 1) {
      _pages.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _finish({required bool askNearby}) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final container = widget.container;
    try {
      final name = _name.text.trim();
      if (name.isNotEmpty) await container.updateProfileName(name);
      final device = _device.text.trim();
      if (device.isNotEmpty && device != container.identity?.displayName) {
        await container.updateCustomDisplayName(device);
      }
      if (askNearby) {
        await container.capabilityCoordinator.requestNearbyAccess();
      }
    } catch (e) {
      // Answers are optional; a failure here must not block the app.
      AppLogger.warning('Onboarding', 'Saving onboarding answers failed: $e');
    }
    await container.completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
              child: Row(
                children: [
                  _Dots(count: _pageCount, index: _page),
                  const Spacer(),
                  if (_page < _pageCount - 1)
                    TextButton(
                      onPressed: () => _pages.animateToPage(
                        _pageCount - 1,
                        duration: const Duration(milliseconds: 360),
                        curve: Curves.easeOutCubic,
                      ),
                      child: const Text('Skip'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _Step(
                    art: const VayuMark(size: 112),
                    title: 'Welcome to Vayu',
                    body: 'Share files with phones nearby.\nNo internet, no accounts.',
                  ),
                  _Step(
                    art: Icon(
                      Icons.badge_outlined,
                      size: 64,
                      color: theme.colorScheme.secondary,
                    ),
                    title: 'What should we call you?',
                    body: 'Your name goes on your Vayu card. Your phone\'s name is what nearby people see.',
                    child: Column(
                      children: [
                        TextField(
                          controller: _name,
                          onChanged: _onNameChanged,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Your name',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _device,
                          maxLength: 32,
                          onChanged: (_) => _deviceEdited = true,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _next(),
                          decoration: const InputDecoration(
                            labelText: 'Phone name',
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Step(
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
                  _Step(
                    art: Icon(
                      Icons.bluetooth_searching_rounded,
                      size: 64,
                      color: theme.colorScheme.secondary,
                    ),
                    title: 'Find phones nearby',
                    body: 'Vayu needs the Nearby devices permission to see other phones. It never tracks your location.',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: _page < _pageCount - 1
                  ? SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton(
                        onPressed: _next,
                        child: Text(_page == 0 ? 'Get started' : 'Continue'),
                      ),
                    )
                  : Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: FilledButton(
                            onPressed: _finishing
                                ? null
                                : () => _finish(askNearby: true),
                            child: const Text('Allow'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _finishing
                              ? null
                              : () => _finish(askNearby: false),
                          child: const Text('Not now'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final Widget art;
  final String title;
  final String? body;
  final Widget? child;

  const _Step({required this.art, required this.title, this.body, this.child});

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
