import 'package:flutter/material.dart';

import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/info_dot.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Everything Vayu needs from the phone, with its live state and one button
/// that fixes it: the system dialog when Android still shows it, otherwise
/// the exact Settings page. Re-checked whenever the user comes back.
class PermissionsPage extends StatefulWidget {
  final AppContainer container;

  const PermissionsPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PermissionsPage(container: container)),
    );
  }

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage>
    with WidgetsBindingObserver {
  PermissionReport? _report;
  bool _busy = false;

  AppContainer get _c => widget.container;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from a Settings page: show what changed there.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    // Discovery and the home banner follow the new state too.
    final report = await _c.permissionManager.recheck();
    if (!mounted) return;
    setState(() => _report = report);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _fixPermission(PermissionGroup group, PermissionStatus status) =>
      _run(() async {
        final settingsPage = group == PermissionGroup.notifications
            ? SettingsPage.notifications
            : SettingsPage.app;
        if (status == PermissionStatus.permanentlyDenied) {
          await _openSettings(settingsPage);
          return;
        }
        final result = await _c.permissionManager.request(group);
        if (result == PermissionState.permanentlyDenied && mounted) {
          showVayuNotice(
            context,
            'Android will not ask again. Allow it on the page that opens.',
          );
          await _openSettings(settingsPage);
        }
      });

  Future<void> _openSettings(SettingsPage page) async {
    final opened = await _c.platformService.openSettingsPage(page);
    if (!opened && mounted) {
      showVayuNotice(
        context,
        'This phone did not open that page. Open Settings, then Apps, then Vayu.',
        tone: VayuNoticeTone.problem,
      );
    }
  }

  Future<void> _turnOnBluetooth() =>
      _run(() => _c.permissionManager.turnOnBluetooth());

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: report == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: _sections(context, report),
              ),
            ),
    );
  }

  List<Widget> _sections(BuildContext context, PermissionReport report) {
    final sdk = report.sdkVersion ?? 0;
    final essential = <Widget>[
      _permissionRow(
        group: PermissionGroup.nearby,
        status: report.statusOf(PermissionGroup.nearby),
        icon: Icons.bluetooth_searching_rounded,
        title: sdk >= 31 ? 'Nearby devices' : 'Location',
        why: sdk >= 31
            ? 'Find phones and connect to them over Bluetooth.'
            : 'Android ${_versionName(sdk)} needs it to find phones over Bluetooth. Vayu never reads your location.',
      ),
      _switchRow(
        state: report.bluetooth,
        icon: Icons.bluetooth_rounded,
        title: 'Bluetooth',
        why: 'Finds phones near you.',
        onFix: _turnOnBluetooth,
        page: SettingsPage.bluetooth,
      ),
      _switchRow(
        state: report.wifi,
        icon: Icons.wifi_rounded,
        title: 'Wi-Fi',
        why: 'The fast way to send. No internet needed.',
        onFix: () => _run(() => _openSettings(SettingsPage.wifi)),
        page: SettingsPage.wifi,
      ),
      _switchRow(
        state: report.location,
        icon: Icons.location_on_outlined,
        title: 'Location',
        why:
            'Android ${_versionName(sdk)} needs Location turned on to find phones and to connect without a shared Wi-Fi.',
        onFix: () => _run(() => _openSettings(SettingsPage.location)),
        page: SettingsPage.location,
      ),
    ];
    final optional = <Widget>[
      _permissionRow(
        group: PermissionGroup.directWifi,
        status: report.statusOf(PermissionGroup.directWifi),
        icon: Icons.wifi_tethering_rounded,
        title: sdk >= 33 ? 'Nearby Wi-Fi devices' : 'Location',
        why: report.approximateLocationOnly && sdk < 33
            ? 'Send when the phones are not on the same Wi-Fi. Needs "Use precise location" on.'
            : 'Send when the phones are not on the same Wi-Fi.',
        approximateOnly: report.approximateLocationOnly && sdk < 33,
      ),
      _switchRow(
        state: report.nfc,
        icon: Icons.contactless_outlined,
        title: 'NFC',
        why: 'Tap phones together to send or share your card.',
        onFix: () => _run(() => _openSettings(SettingsPage.nfc)),
        page: SettingsPage.nfc,
      ),
      _permissionRow(
        group: PermissionGroup.camera,
        status: report.statusOf(PermissionGroup.camera),
        icon: Icons.qr_code_scanner_rounded,
        title: 'Camera',
        why: 'Scan the code on another phone.',
      ),
      _permissionRow(
        group: PermissionGroup.notifications,
        status: report.statusOf(PermissionGroup.notifications),
        icon: Icons.notifications_none_rounded,
        title: 'Notifications',
        why: 'Shows progress while a big transfer runs in the background.',
      ),
      _permissionRow(
        group: PermissionGroup.storage,
        status: report.statusOf(PermissionGroup.storage),
        icon: Icons.folder_outlined,
        title: 'Storage',
        why: 'Saves received files to Downloads/Vayu.',
      ),
      _switchRow(
        state: report.battery,
        icon: Icons.battery_charging_full_rounded,
        title: 'Unrestricted battery',
        why: 'Keeps long transfers going with the screen off. Choose "Unrestricted" or "Don\'t optimise" for Vayu.',
        onFix: () => _run(() => _openSettings(SettingsPage.battery)),
        page: SettingsPage.battery,
        onLabel: 'Unrestricted',
        offLabel: 'Optimised',
        fixLabel: 'Open settings',
      ),
    ];

    final visibleEssential = essential.whereType<_Row>().toList();
    final visibleOptional = optional.whereType<_Row>().toList();
    return [
      if (visibleEssential.isNotEmpty) ...[
        const SectionHeader(title: 'Needed to find phones'),
        _card(visibleEssential),
        const SizedBox(height: 20),
      ],
      if (visibleOptional.isNotEmpty) ...[
        const SectionHeader(title: 'Used by some features'),
        _card(visibleOptional),
        const SizedBox(height: 16),
      ],
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.settings_outlined),
        title: const Text('All of Vayu\'s phone settings'),
        trailing: const Icon(Icons.open_in_new_rounded, size: 18),
        onTap: () => _run(() => _openSettings(SettingsPage.app)),
      ),
    ];
  }

  Widget _card(List<_Row> rows) {
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, thickness: 0.5),
            rows[i],
          ],
        ],
      ),
    );
  }

  /// A permission row, or nothing when this Android version does not need it.
  Widget _permissionRow({
    required PermissionGroup group,
    required PermissionStatus status,
    required IconData icon,
    required String title,
    required String why,
    bool approximateOnly = false,
  }) {
    if (status == PermissionStatus.notRequired) return const SizedBox.shrink();
    final settingsPage = group == PermissionGroup.notifications
        ? SettingsPage.notifications
        : SettingsPage.app;
    if (approximateOnly && status != PermissionStatus.granted) {
      // Settings shows Location as allowed; only the precise switch is off.
      return _Row(
        icon: icon,
        title: title,
        why: why,
        statusLabel: 'Approximate only',
        tone: _Tone.warn,
        // Asking again shows Android's "Use precise location?" dialog.
        actionLabel: status == PermissionStatus.permanentlyDenied
            ? 'Open settings'
            : 'Allow',
        onAction: _busy ? null : () => _fixPermission(group, status),
      );
    }
    final (label, tone) = switch (status) {
      PermissionStatus.granted => ('Allowed', _Tone.good),
      PermissionStatus.permanentlyDenied => ('Blocked', _Tone.bad),
      PermissionStatus.denied => ('Not allowed', _Tone.warn),
      _ => ('Not asked yet', _Tone.warn),
    };
    return _Row(
      icon: icon,
      title: title,
      why: why,
      statusLabel: label,
      tone: tone,
      // Allowed rows still lead to Settings, where it can be changed.
      actionLabel: switch (status) {
        PermissionStatus.granted => 'Manage',
        PermissionStatus.permanentlyDenied => 'Open settings',
        _ => 'Allow',
      },
      onAction: _busy
          ? null
          : status == PermissionStatus.granted
          ? () => _run(() => _openSettings(settingsPage))
          : () => _fixPermission(group, status),
    );
  }

  Widget _switchRow({
    required SwitchState state,
    required IconData icon,
    required String title,
    required String why,
    required VoidCallback onFix,
    required SettingsPage page,
    String onLabel = 'On',
    String offLabel = 'Off',
    String fixLabel = 'Turn on',
  }) {
    if (state == SwitchState.notNeeded || state == SwitchState.unknown) {
      return const SizedBox.shrink();
    }
    if (state == SwitchState.unsupported) {
      return _Row(
        icon: icon,
        title: title,
        why: 'This phone does not have it.',
        statusLabel: 'Not on this phone',
        tone: _Tone.neutral,
      );
    }
    final on = state == SwitchState.on;
    return _Row(
      icon: icon,
      title: title,
      why: why,
      statusLabel: on ? onLabel : offLabel,
      tone: on ? _Tone.good : _Tone.warn,
      actionLabel: on ? 'Settings' : fixLabel,
      onAction: _busy
          ? null
          : on
          ? () => _run(() => _openSettings(page))
          : onFix,
    );
  }

  static String _versionName(int sdk) {
    final name = PermissionManager.androidVersionName(sdk);
    return name.isEmpty ? 'on this version' : name;
  }
}

enum _Tone { good, warn, bad, neutral }

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String why;
  final String statusLabel;
  final _Tone tone;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _Row({
    required this.icon,
    required this.title,
    required this.why,
    required this.statusLabel,
    required this.tone,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final (fg, bg) = switch (tone) {
      _Tone.good => (palette.success, palette.successContainer),
      _Tone.warn => (palette.warning, palette.warningContainer),
      _Tone.bad => (palette.danger, palette.dangerContainer),
      _Tone.neutral => (
        theme.colorScheme.onSurfaceVariant,
        theme.colorScheme.surfaceContainerHighest,
      ),
    };
    return Semantics(
      container: true,
      label: '$title, $statusLabel',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(title, style: theme.textTheme.titleSmall),
                      ),
                      InfoDot(title: title, message: why),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Pill and button wrap onto two lines with large text.
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ExcludeSemantics(
                        child: StatusPill(
                          label: statusLabel,
                          foreground: fg,
                          background: bg,
                        ),
                      ),
                      if (actionLabel != null)
                        FilledButton.tonal(
                          onPressed: onAction,
                          child: Text(actionLabel!),
                        ),
                    ],
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
