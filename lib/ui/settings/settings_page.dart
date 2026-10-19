import 'package:flutter/material.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_orchestrator.dart';
import 'package:vayu/ui/diagnostics/diagnostics_page.dart';
import 'package:vayu/ui/settings/permissions_page.dart';
import 'package:vayu/ui/widgets/info_dot.dart';
import 'package:vayu/ui/settings/permissions_rationale_dialog.dart';
import 'package:vayu/ui/widgets/rename_device_sheet.dart';
import 'package:vayu/ui/card/my_card_page.dart';

/// Settings Screen (UI10, UI9, Section 30 & 31).
///
/// Provides user controls for:
/// - Local device display name customization (and re-advertising)
/// - Battery Saver policy (Off, On, Follow System) with transparent trade-offs
/// - Downloads directory path inspection
/// - Permission status and rationale dialog
/// - Diagnostics & live telemetry navigation
/// - Privacy and version information
class SettingsPage extends StatefulWidget {
  final AppContainer container;

  const SettingsPage({super.key, required this.container});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _downloadsDir;
  bool _isLoadingDownloads = false;

  @override
  void initState() {
    super.initState();
    _loadDownloadsDir();
  }

  Future<void> _loadDownloadsDir() async {
    setState(() => _isLoadingDownloads = true);
    try {
      final dir = await widget.container.storageService.getDownloadsDirectory();
      if (mounted) {
        setState(() {
          _downloadsDir = dir;
          _isLoadingDownloads = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingDownloads = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final container = widget.container;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: StreamBuilder<UserSettings>(
        stream: container.userSettingsStream,
        initialData: container.userSettings,
        builder: (context, settingsSnapshot) {
          final settings = settingsSnapshot.data ?? container.userSettings;

          return StreamBuilder<AppOrchestratorState>(
            stream: container.orchestratorStateStream,
            initialData: container.orchestrator.currentState,
            builder: (context, orchSnapshot) {
              final orchState =
                  orchSnapshot.data ?? container.orchestrator.currentState;

              return ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 12.0,
                ),
                children: [
                  // 1. Device Profile & Display Name
                  _buildSectionHeader(theme, 'You'),
                  _buildProfileCard(context, theme, container),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Appearance'),
                  _buildAppearanceCard(theme, container, settings),
                  const SizedBox(height: 16),

                  // 2. Battery Saver UI (UI9 & Section 30)
                  _buildSectionHeader(theme, 'Battery'),
                  _buildBatterySaverCard(theme, container, settings, orchState),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Nearby phones'),
                  _buildRelayCard(theme, container, settings),
                  const SizedBox(height: 16),

                  // 3. Storage & Downloads Directory
                  _buildSectionHeader(theme, 'Storage'),
                  _buildStorageCard(theme),
                  const SizedBox(height: 16),

                  // 4. Permissions & Privacy
                  _buildSectionHeader(theme, 'Privacy'),
                  _buildPermissionsCard(context, theme, container),
                  const SizedBox(height: 16),

                  // 5. Diagnostics & Troubleshooting (UI11)
                  _buildSectionHeader(theme, 'Advanced'),
                  _buildDiagnosticsCard(context, theme, container),
                  const SizedBox(height: 16),

                  // 6. About Vayu
                  _buildSectionHeader(theme, 'About'),
                  _buildAboutCard(theme),
                  const SizedBox(height: 24),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAppearanceCard(
    ThemeData theme,
    AppContainer container,
    UserSettings settings,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Theme', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            SegmentedButton<AppThemePreference>(
              segments: const [
                ButtonSegment(
                  value: AppThemePreference.system,
                  icon: Icon(Icons.brightness_auto_rounded),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: AppThemePreference.light,
                  icon: Icon(Icons.light_mode_rounded),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: AppThemePreference.dark,
                  icon: Icon(Icons.dark_mode_rounded),
                  label: Text('Dark'),
                ),
              ],
              selected: {settings.themePreference},
              onSelectionChanged: (selection) =>
                  container.setThemePreference(selection.first),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4.0, bottom: 6.0),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildProfileCard(
    BuildContext context,
    ThemeData theme,
    AppContainer container,
  ) {
    final currentName = container.identity?.displayName ?? 'Vayu-Device';
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: const Icon(Icons.devices_rounded),
            ),
            title: Text(
              currentName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: const Text('Your phone name'),
            trailing: FilledButton.tonal(
              onPressed: () => _showEditNameDialog(context, currentName),
              child: const Text('Edit'),
            ),
          ),
          const Divider(height: 1, thickness: 0.5),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.secondaryContainer,
              foregroundColor: theme.colorScheme.onSecondaryContainer,
              child: const Icon(Icons.badge_outlined),
            ),
            title: const Text('Profile'),
            subtitle: Text(
              container.myCard == null
                  ? 'Set up your name and card'
                  : 'Your card, shared by tap',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => MyCardPage.open(context, container),
          ),
        ],
      ),
    );
  }

  Widget _buildBatterySaverCard(
    ThemeData theme,
    AppContainer container,
    UserSettings settings,
    AppOrchestratorState orchState,
  ) {
    final isThrottled = orchState.isBatterySaverActive;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isThrottled
                          ? Icons.battery_saver_rounded
                          : Icons.battery_std_rounded,
                      color: isThrottled
                          ? VayuPalette.fromTheme(theme).warning
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Battery saver',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    InfoDot(
                      title: 'Battery saver',
                      message: settings.batterySaverMode.description,
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isThrottled
                        ? VayuPalette.fromTheme(theme).warningContainer
                        : VayuPalette.fromTheme(theme).successContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isThrottled ? 'Active' : 'Standard',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isThrottled
                          ? VayuPalette.fromTheme(theme).warning
                          : VayuPalette.fromTheme(theme).success,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<BatterySaverMode>(
              segments: const [
                ButtonSegment(value: BatterySaverMode.off, label: Text('Off')),
                ButtonSegment(value: BatterySaverMode.on, label: Text('On')),
                ButtonSegment(
                  value: BatterySaverMode.system,
                  label: Text('Auto'),
                ),
              ],
              selected: {settings.batterySaverMode},
              onSelectionChanged: (selected) {
                if (selected.isNotEmpty) {
                  container.setBatterySaverMode(selected.first);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStorageCard(ThemeData theme) {
    return Card(
      child: ListTile(
        leading: Icon(Icons.folder_rounded, color: theme.colorScheme.primary),
        title: const Text(
          'Received files',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: _isLoadingDownloads
            ? const Text('Loading…')
            : Text(
                _downloadsDir ?? 'Default system downloads',
                style: const TextStyle(fontSize: 12),
              ),
      ),
    );
  }

  /// Phase 12 mesh: relaying for others, off unless the user turns it on.
  Widget _buildRelayCard(
    ThemeData theme,
    AppContainer container,
    UserSettings settings,
  ) {
    final relay = container.relayService;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: Icon(
              Icons.device_hub_rounded,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Help nearby phones connect'),
            subtitle: const Text(
              'Pass encrypted connections between phones that cannot reach '
              'each other. You never see what they send.',
            ),
            value: settings.relayEnabled,
            onChanged: (on) => container.setRelayEnabled(on),
          ),
          if (settings.relayEnabled && relay != null) ...[
            const Divider(height: 1, thickness: 0.5),
            StreamBuilder<void>(
              stream: relay.changes,
              builder: (context, _) {
                final n = relay.relayingCount;
                return ListTile(
                  leading: Icon(
                    Icons.swap_horiz_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    n == 0
                        ? 'Not relaying anything now'
                        : 'Relaying $n ${n == 1 ? 'connection' : 'connections'} now',
                  ),
                  subtitle: const Text(
                    'Stops on Battery Saver or below 20% battery. At most 2 '
                    'at a time.',
                  ),
                  trailing: const InfoDot(
                    title: 'Relaying',
                    message:
                        'Phones relayed through yours stay end-to-end '
                        'encrypted: your phone forwards scrambled data and '
                        'cannot read messages or files. It can see which two '
                        'phones talk, and when. Only phones that have met '
                        'directly before can reach each other this way.',
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPermissionsCard(
    BuildContext context,
    ThemeData theme,
    AppContainer container,
  ) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              Icons.call_received_rounded,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Receiving'),
            subtitle: const Text(
              'On the Receive screen, or files you accept in a chat or ask a '
              'host for',
            ),
            trailing: const InfoDot(
              title: 'Receiving',
              message:
                  'Files are accepted only while Receive is open, when you '
                  'accept them in a chat, or when you download them from a '
                  'host. Nobody nearby can send you popups.',
            ),
          ),
          const Divider(height: 1, thickness: 0.5),
          ListTile(
            leading: Icon(
              Icons.verified_user_outlined,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Permissions & settings'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => PermissionsPage.open(context, container),
          ),
          const Divider(height: 1, thickness: 0.5),
          ListTile(
            leading: Icon(
              Icons.shield_outlined,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Why Vayu asks for permissions'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => PermissionsRationaleDialog.show(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticsCard(
    BuildContext context,
    ThemeData theme,
    AppContainer container,
  ) {
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.analytics_outlined,
          color: theme.colorScheme.primary,
        ),
        title: const Text(
          'Diagnostics',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: const Text('Connection details and transfer speed'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => DiagnosticsPage(container: container),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAboutCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lock_outline_rounded, size: 18),
                const SizedBox(width: 8),
                Text(
                  '${AppConstants.appName} by Achyrio',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                const Text(
                  'v1.0.0',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Share files with phones nearby. Encrypted, offline, no account.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditNameDialog(BuildContext context, String currentName) {
    return showRenameDeviceSheet(
      context,
      container: widget.container,
      currentName: currentName,
    );
  }
}
