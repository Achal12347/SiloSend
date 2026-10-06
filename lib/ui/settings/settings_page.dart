import 'package:flutter/material.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_orchestrator.dart';
import 'package:vayu/ui/diagnostics/diagnostics_page.dart';
import 'package:vayu/ui/settings/permissions_rationale_dialog.dart';

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
      appBar: AppBar(
        title: const Text('Settings'),
      ),
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
                  _buildSectionHeader(theme, 'Device Identity'),
                  _buildProfileCard(context, theme, container),
                  const SizedBox(height: 16),

                  // 2. Battery Saver UI (UI9 & Section 30)
                  _buildSectionHeader(theme, 'Battery Saver'),
                  _buildBatterySaverCard(theme, container, settings, orchState),
                  const SizedBox(height: 16),

                  // 3. Storage & Downloads Directory
                  _buildSectionHeader(theme, 'Storage'),
                  _buildStorageCard(theme),
                  const SizedBox(height: 16),

                  // 4. Permissions & Privacy
                  _buildSectionHeader(theme, 'Permissions & Privacy'),
                  _buildPermissionsCard(context, theme, container),
                  const SizedBox(height: 16),

                  // 5. Diagnostics & Troubleshooting (UI11)
                  _buildSectionHeader(theme, 'Diagnostics'),
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
    final deviceId = container.identity?.idHex ?? '';
    final shortId = deviceId.length >= 8 ? deviceId.substring(0, 8) : deviceId;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          child: const Icon(Icons.devices_rounded),
        ),
        title: Text(
          currentName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('Device ID: $shortId...'),
        trailing: FilledButton.tonal(
          onPressed: () => _showEditNameDialog(context, currentName),
          child: const Text('Edit'),
        ),
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
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
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
                          ? Colors.orange.shade800
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Power Saving Policy',
                      style: TextStyle(fontWeight: FontWeight.bold),
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
                        ? Colors.orange.shade100
                        : Colors.green.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isThrottled ? 'Active' : 'Standard',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isThrottled
                          ? Colors.orange.shade900
                          : Colors.green.shade900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<BatterySaverMode>(
              segments: const [
                ButtonSegment(
                  value: BatterySaverMode.off,
                  label: Text('Off'),
                ),
                ButtonSegment(
                  value: BatterySaverMode.on,
                  label: Text('On'),
                ),
                ButtonSegment(
                  value: BatterySaverMode.system,
                  label: Text('Follow System'),
                ),
              ],
              selected: {settings.batterySaverMode},
              onSelectionChanged: (selected) {
                if (selected.isNotEmpty) {
                  container.setBatterySaverMode(selected.first);
                }
              },
            ),
            const SizedBox(height: 12),
            Text(
              settings.batterySaverMode.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Vayu will reduce unnecessary background discovery and consider '
              'battery usage when selecting transports. High-speed LAN is still chosen '
              'for large files to minimize radio active time.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStorageCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: ListTile(
        leading: Icon(Icons.folder_rounded, color: theme.colorScheme.primary),
        title: const Text(
          'Downloads Directory',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: _isLoadingDownloads
            ? const Text('Loading path...')
            : Text(
                _downloadsDir ?? 'Default system downloads',
                style: const TextStyle(fontSize: 12),
              ),
      ),
    );
  }

  Widget _buildPermissionsCard(
    BuildContext context,
    ThemeData theme,
    AppContainer container,
  ) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              Icons.shield_outlined,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Permission Rationale'),
            subtitle: const Text('Why Vayu needs local radio access'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => PermissionsRationaleDialog.show(context),
          ),
          const Divider(height: 1, thickness: 0.5),
          ListTile(
            leading: Icon(
              Icons.settings_outlined,
              color: theme.colorScheme.primary,
            ),
            title: const Text('System App Settings'),
            subtitle: const Text('Manage permissions in device settings'),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: () => container.platformService.openAppSettings(),
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
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: ListTile(
        leading: Icon(Icons.analytics_outlined, color: theme.colorScheme.primary),
        title: const Text(
          'Diagnostics & Telemetry',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: const Text('Live hardware, network, and radio logs'),
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
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
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
              'Vayu is a product by Achyrio. Local-first, encrypted peer-to-peer data sharing '
              'without intermediaries, cloud servers, or account logins. Built for speed, privacy, and resilience.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditNameDialog(
    BuildContext context,
    String currentName,
  ) async {
    final textController = TextEditingController(text: currentName);
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Device Name'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: textController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Display Name',
              hintText: 'e.g. My Phone',
            ),
            validator: (val) {
              if (val == null || val.trim().isEmpty) {
                return 'Name cannot be empty';
              }
              if (val.trim().length > 32) {
                return 'Name must be 32 characters or fewer';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (formKey.currentState?.validate() == true) {
                final newName = textController.text.trim();
                final messenger = ScaffoldMessenger.of(context);
                Navigator.of(ctx).pop();
                try {
                  await widget.container.updateCustomDisplayName(newName);
                  if (mounted) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('Device name updated to "$newName"'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('Failed to update name: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
