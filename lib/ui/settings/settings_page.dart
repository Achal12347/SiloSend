import 'package:flutter/material.dart';

import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/card/my_card_page.dart';
import 'package:vayu/ui/diagnostics/diagnostics_page.dart';
import 'package:vayu/ui/security/trusted_devices_page.dart';
import 'package:vayu/ui/settings/about_page.dart';
import 'package:vayu/ui/settings/device_name_page.dart';
import 'package:vayu/ui/settings/permissions_page.dart';
import 'package:vayu/ui/settings/your_data_page.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Settings holds only what can be changed here and links to other pages.
/// Explanations belong on the page they explain.
class SettingsPage extends StatelessWidget {
  final AppContainer container;

  const SettingsPage({super.key, required this.container});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: StreamBuilder<UserSettings>(
        stream: container.userSettingsStream,
        initialData: container.userSettings,
        builder: (context, snapshot) {
          final settings = snapshot.data ?? container.userSettings;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              const SectionHeader(title: 'You'),
              Card(
                child: Column(
                  children: [
                    _LinkRow(
                      icon: Icons.badge_outlined,
                      title: 'Profile',
                      onTap: () => MyCardPage.open(context, container),
                    ),
                    const _RowDivider(),
                    _LinkRow(
                      icon: Icons.smartphone_rounded,
                      title: 'Phone name',
                      value: container.identity?.displayName,
                      onTap: () => DeviceNamePage.open(context, container),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader(title: 'Preferences'),
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ChoiceRow<AppThemePreference>(
                      title: 'Theme',
                      selected: settings.themePreference,
                      options: const {
                        AppThemePreference.system: 'System',
                        AppThemePreference.light: 'Light',
                        AppThemePreference.dark: 'Dark',
                      },
                      onChanged: container.setThemePreference,
                    ),
                    const _RowDivider(),
                    _ChoiceRow<BatterySaverMode>(
                      title: 'Battery saver',
                      selected: settings.batterySaverMode,
                      options: const {
                        BatterySaverMode.off: 'Off',
                        BatterySaverMode.on: 'On',
                        BatterySaverMode.system: 'Auto',
                      },
                      onChanged: container.setBatterySaverMode,
                    ),
                    const _RowDivider(),
                    SwitchListTile(
                      title: const Text('Chat messages in the background'),
                      subtitle: const Text(
                        'Keeps a silent notification. Uses more battery.',
                      ),
                      value: settings.chatListeningEnabled,
                      onChanged: container.setChatListeningEnabled,
                    ),
                    const _RowDivider(),
                    SwitchListTile(
                      title: const Text('Help nearby phones connect'),
                      // Kept here: this is what the user agrees to by turning
                      // it on.
                      subtitle: const Text(
                        'Forwards encrypted data. It shows which phones are '
                        'talking, never what they send.',
                      ),
                      value: settings.relayEnabled,
                      onChanged: container.setRelayEnabled,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader(title: 'Privacy and security'),
              Card(
                child: Column(
                  children: [
                    _LinkRow(
                      icon: Icons.tune_rounded,
                      title: 'Permissions',
                      onTap: () => PermissionsPage.open(context, container),
                    ),
                    const _RowDivider(),
                    _LinkRow(
                      icon: Icons.verified_user_outlined,
                      title: 'Trusted devices',
                      onTap: () => TrustedDevicesPage.open(context, container),
                    ),
                    const _RowDivider(),
                    _LinkRow(
                      icon: Icons.folder_shared_outlined,
                      title: 'Your data',
                      onTap: () => YourDataPage.open(context, container),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionHeader(title: 'More'),
              Card(
                child: Column(
                  children: [
                    _LinkRow(
                      icon: Icons.analytics_outlined,
                      title: 'Diagnostics',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DiagnosticsPage(container: container),
                        ),
                      ),
                    ),
                    const _RowDivider(),
                    _LinkRow(
                      icon: Icons.info_outline_rounded,
                      title: 'About',
                      onTap: () => AboutPage.open(context, container),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) => const Divider(height: 1);
}

/// A row that opens another page.
class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback onTap;

  const _LinkRow({
    required this.icon,
    required this.title,
    this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: value == null ? null : Text(value!),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}

/// A setting with a few choices, shown as one segmented control.
class _ChoiceRow<T> extends StatelessWidget {
  final String title;
  final T selected;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  const _ChoiceRow({
    required this.title,
    required this.selected,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 10),
          SegmentedButton<T>(
            showSelectedIcon: false,
            segments: [
              for (final option in options.entries)
                ButtonSegment(value: option.key, label: Text(option.value)),
            ],
            selected: {selected},
            onSelectionChanged: (selection) => onChanged(selection.first),
          ),
        ],
      ),
    );
  }
}
