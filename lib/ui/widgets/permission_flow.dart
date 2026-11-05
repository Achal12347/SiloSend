import 'package:flutter/material.dart';

import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Makes [feature] ready before the action that needs it runs.
///
/// Returns true when nothing is missing (straight away if it already was),
/// so the caller simply goes on with what the user asked for. Otherwise a
/// sheet explains what is missing and why, then offers the one step that
/// fixes it: the system dialog while Android still shows it, else the exact
/// Settings page. The sheet re-checks when the user comes back and closes
/// itself once everything is in place. False when the user chose not to.
///
/// [alreadyExplained]: the screen already said why (a banner with an Allow
/// button), so the first system dialog is shown without the sheet.
Future<bool> ensureFeature(
  BuildContext context,
  AppContainer container,
  VayuFeature feature, {
  bool alreadyExplained = false,
}) async {
  final manager = container.permissionManager;
  var blockers = await manager.check(feature);
  if (blockers.isEmpty) return true;

  if (alreadyExplained && blockers.first.canAsk) {
    await manager.request(blockers.first.group!);
    blockers = await manager.check(feature);
    if (blockers.isEmpty) return true;
  }
  if (!context.mounted) return false;
  final ready = await showVayuSheet<bool>(
    context: context,
    builder: (_) => PermissionFixSheet(
      manager: manager,
      feature: feature,
      initialBlockers: blockers,
    ),
  );
  return ready ?? false;
}

/// The baseline, shown once on Home after onboarding: what finding nearby
/// phones needs (permission, then Bluetooth, then Location where Android
/// requires it). Everything else is asked when the user starts what needs it.
Future<void> askBaselinePermissions(
  BuildContext context,
  AppContainer container,
) async {
  await container.markBaselinePermissionsAsked();
  if (!context.mounted) return;
  final ready = await ensureFeature(context, container, VayuFeature.findPhones);
  if (!ready) return;
  // Android 13+ lists this under the same "Nearby devices" permission, so
  // allowing it here avoids a second question in the middle of a transfer.
  final manager = container.permissionManager;
  final report = await manager.refresh();
  if ((report.sdkVersion ?? 0) >= 33 &&
      manager.stateOf(PermissionGroup.directWifi, report) ==
          PermissionState.notRequested) {
    await manager.request(PermissionGroup.directWifi);
  }
}

/// For screens that search for phones: walks through what is missing when
/// Bluetooth is the only way to find phones, or the permission was never
/// asked. On a shared Wi-Fi phones are found anyway, so the Home banner offers
/// the rest instead of a sheet on every visit. True when nothing is missing.
Future<bool> ensureFindPhonesIfNeeded(
  BuildContext context,
  AppContainer container,
) async {
  final blockers = await container.permissionManager.check(
    VayuFeature.findPhones,
  );
  if (blockers.isEmpty) return true;
  final neverAsked = blockers.first.state == PermissionState.notRequested;
  if (container.capabilityCoordinator.rawCapabilities.canUseLan &&
      !neverAsked) {
    return false;
  }
  if (!context.mounted) return false;
  return ensureFeature(context, container, VayuFeature.findPhones);
}

/// Sheet that walks through what [feature] is missing, one item at a time.
class PermissionFixSheet extends StatefulWidget {
  final PermissionManager manager;
  final VayuFeature feature;
  final List<Blocker> initialBlockers;

  const PermissionFixSheet({
    super.key,
    required this.manager,
    required this.feature,
    required this.initialBlockers,
  });

  @override
  State<PermissionFixSheet> createState() => _PermissionFixSheetState();
}

class _PermissionFixSheetState extends State<PermissionFixSheet>
    with WidgetsBindingObserver {
  late List<Blocker> _blockers = widget.initialBlockers;
  bool _busy = false;

  /// Set after sending the user to a Settings page; the sheet then waits for
  /// them to come back.
  bool _waitingForReturn = false;
  bool _settingsFailed = false;

  PermissionManager get _m => widget.manager;

  int get _sdk => _m.lastReport?.sdkVersion ?? 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _recheck(fromSettings: true);
  }

  // The system dialog closing also resumes the app, so two re-checks can
  // finish together; only the first may close the sheet.
  bool _closed = false;

  void _close(bool ready) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(ready);
  }

  Future<void> _recheck({bool fromSettings = false}) async {
    final report = fromSettings ? await _m.recheck() : await _m.refresh();
    if (!mounted || _closed) return;
    final blockers = _m.blockersFor(widget.feature, report);
    if (blockers.isEmpty) {
      // Everything is in place: the original action continues.
      _close(true);
      return;
    }
    setState(() {
      _blockers = blockers;
      if (fromSettings) _waitingForReturn = false;
    });
  }

  Future<void> _act(Blocker blocker) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _settingsFailed = false;
    });
    try {
      switch (blocker.kind) {
        case BlockerKind.permission when blocker.canAsk:
          await _m.request(blocker.group!);
          await _recheck();
        case BlockerKind.bluetoothOff:
          if (await _m.turnOnBluetooth()) {
            await _recheck();
          } else if (mounted) {
            setState(() => _waitingForReturn = true);
          }
        case BlockerKind.unsupported:
          _close(false);
        default:
          final opened = await _m.openSettingsFor(blocker);
          if (mounted) {
            setState(() {
              _waitingForReturn = opened;
              _settingsFailed = !opened;
            });
          }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocker = _blockers.first;
    final text = describeBlocker(
      blocker,
      widget.feature,
      _sdk,
      approximateLocationOnly: _m.lastReport?.approximateLocationOnly ?? false,
    );
    final theme = Theme.of(context);
    return VayuSheet(
      title: text.title,
      message: text.message,
      content: _waitingForReturn || _settingsFailed
          ? Text(
              _settingsFailed
                  ? 'This phone did not open that page. Open Settings, then Apps, then Vayu.'
                  : 'Come back to Vayu when you are done. It continues by itself.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _settingsFailed
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      actions: [
        if (text.actionLabel != null)
          FilledButton(
            onPressed: _busy ? null : () => _act(blocker),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(text.actionLabel!),
          ),
        TextButton(
          onPressed: () => _close(false),
          child: Text(text.actionLabel == null ? 'Close' : 'Not now'),
        ),
      ],
    );
  }
}

/// Title, explanation and button for one [Blocker] of [feature] on [sdk].
({String title, String message, String? actionLabel}) describeBlocker(
  Blocker blocker,
  VayuFeature feature,
  int sdk, {
  bool approximateLocationOnly = false,
}) {
  final version = PermissionManager.androidVersionName(sdk);
  final android = version.isEmpty ? 'Android' : 'Android $version';
  const noLocation = 'Vayu never reads your location.';

  switch (blocker.kind) {
    case BlockerKind.unsupported:
      return (
        title: 'No Bluetooth on this phone',
        message: 'You can still share with phones on the same Wi-Fi.',
        actionLabel: null,
      );
    case BlockerKind.bluetoothOff:
      return (
        title: 'Turn on Bluetooth',
        message: 'Vayu finds phones near you over Bluetooth.',
        actionLabel: 'Turn on',
      );
    case BlockerKind.wifiOff:
      return (
        title: 'Turn on Wi-Fi',
        message: 'A direct connection between phones uses Wi-Fi. No internet is needed.',
        actionLabel: 'Open Wi-Fi',
      );
    case BlockerKind.locationOff:
      return (
        title: 'Turn on Location',
        message: feature == VayuFeature.findPhones
            ? '$android only finds Bluetooth devices while Location is on. $noLocation'
            : '$android needs Location on to connect phones directly. $noLocation',
        actionLabel: 'Open Location settings',
      );
    case BlockerKind.permission:
      final group = blocker.group!;
      final name = permissionName(group, sdk);
      // Android 12 lists Location as allowed when only "Approximate" was
      // chosen; the direct connection still needs the precise one.
      if (group == PermissionGroup.directWifi &&
          sdk < 33 &&
          approximateLocationOnly) {
        return (
          title: 'Turn on precise location',
          message:
              '$android connects phones directly only with precise location. '
              'On the page that opens, tap Permissions, Location, then turn on '
              '"Use precise location". $noLocation',
          actionLabel: blocker.state == PermissionState.permanentlyDenied
              ? 'Open settings'
              : 'Allow',
        );
      }
      if (blocker.state == PermissionState.permanentlyDenied) {
        return (
          title: '$name is blocked',
          message: group == PermissionGroup.notifications
              ? 'Android will not ask again. Turn on notifications for Vayu on the page that opens.'
              : 'Android will not ask again. On the page that opens, tap Permissions and allow $name.',
          actionLabel: 'Open settings',
        );
      }
      final why = switch ((group, feature)) {
        (PermissionGroup.camera, _) =>
          'Vayu uses the camera only to scan the code on the other phone.',
        (PermissionGroup.notifications, VayuFeature.chatNotifications) =>
          'Lets Vayu alert you when a nearby phone sends a chat message.',
        (PermissionGroup.notifications, _) =>
          'Shows progress while a long transfer runs with the screen off.',
        (PermissionGroup.storage, _) =>
          '$android needs it to save received files to Downloads/Vayu.',
        (PermissionGroup.directWifi, _) =>
          sdk >= 33
              ? 'Lets this phone connect straight to the other phone when you are not on the same Wi-Fi.'
              : '$android needs it to connect phones directly without a shared Wi-Fi. $noLocation',
        (PermissionGroup.nearby, VayuFeature.directWifi) =>
          '$android needs it to connect phones directly without a shared Wi-Fi. $noLocation',
        (PermissionGroup.nearby, _) =>
          sdk >= 31
              ? 'Vayu uses it to find phones near you over Bluetooth. $noLocation'
              : '$android needs it to find phones over Bluetooth. $noLocation',
      };
      final again =
          blocker.state == PermissionState.rationaleRequired ||
          blocker.state == PermissionState.deniedRequestable;
      return (
        title: again ? '$name is still off' : 'Allow $name',
        message: why,
        actionLabel: 'Allow',
      );
  }
}

/// The name Android shows for [group] on [sdk].
String permissionName(PermissionGroup group, int sdk) => switch (group) {
  PermissionGroup.nearby => sdk >= 31 ? 'Nearby devices' : 'Location',
  PermissionGroup.directWifi => sdk >= 33 ? 'Nearby Wi-Fi devices' : 'Location',
  PermissionGroup.camera => 'Camera',
  PermissionGroup.notifications => 'Notifications',
  PermissionGroup.storage => 'Storage',
};
