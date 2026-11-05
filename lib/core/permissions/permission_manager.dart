import 'dart:async';

import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';

/// Things the user can do in Vayu that need something from the phone.
///
/// [findPhones] is the baseline, asked once on Home after onboarding. The
/// others are asked when the user starts something that needs them.
enum VayuFeature {
  /// Finding phones over Bluetooth (Wi-Fi discovery needs nothing).
  findPhones,

  /// Connecting phones that are not on the same Wi-Fi (Wi-Fi Direct group
  /// or a phone-hosted hotspot).
  directWifi,

  /// Scanning the code on another phone.
  scanCode,

  /// Notifying the user about nearby chat messages.
  chatNotifications,

  /// The progress notification of long transfers (Android 13+).
  transferNotifications,

  /// Saving received files to the shared Downloads folder (Android 8-10).
  saveToDownloads,
}

/// What Vayu knows about one runtime permission group.
///
/// "Restricted by device policy" is not listed: Android gives an ordinary
/// app no reliable way to tell it apart from a permanent refusal, and Vayu
/// does not guess.
enum PermissionState {
  /// Never answered.
  notRequested,

  /// Refused once; Android will still ask. Explain before asking again.
  rationaleRequired,

  /// The system dialog is showing.
  requesting,

  granted,

  /// Refused (or the dialog was dismissed); Android will still ask.
  deniedRequestable,

  /// Android will not show the dialog any more; only Settings can change it.
  permanentlyDenied,

  /// This Android version does not need it.
  notRequired,

  /// The platform could not report it (the action is tried as usual).
  unknown,
}

enum BlockerKind { permission, bluetoothOff, locationOff, wifiOff, unsupported }

/// One thing standing between a feature and working.
class Blocker {
  final BlockerKind kind;

  /// Set for [BlockerKind.permission].
  final PermissionGroup? group;
  final PermissionState? state;

  const Blocker.permission(
    PermissionGroup this.group,
    PermissionState this.state,
  ) : kind = BlockerKind.permission;

  const Blocker.switchOff(this.kind) : group = null, state = null;

  /// True when the system dialog can still be shown for it.
  bool get canAsk =>
      kind == BlockerKind.permission &&
      state != PermissionState.permanentlyDenied;

  @override
  String toString() => kind == BlockerKind.permission
      ? 'Blocker(${group!.name}: ${state!.name})'
      : 'Blocker(${kind.name})';
}

/// Single source of permission and system-switch state for every screen.
///
/// Reads the live state from the platform each time it is asked, so a change
/// made in system Settings is seen as soon as the user comes back.
class PermissionManager {
  final PlatformService _platform;

  /// Runs after anything may have changed (discovery and the home banner
  /// follow the new state).
  final Future<void> Function()? onChanged;

  final Set<PermissionGroup> _requesting = {};
  PermissionReport? _last;

  PermissionManager(this._platform, {this.onChanged});

  /// The last report read, if any.
  PermissionReport? get lastReport => _last;

  /// Reads the current state from the platform.
  Future<PermissionReport> refresh() async =>
      _last = await _platform.permissionReport();

  /// What is missing for [feature] right now. Empty means ready.
  Future<List<Blocker>> check(VayuFeature feature) async =>
      blockersFor(feature, await refresh());

  PermissionState stateOf(PermissionGroup group, PermissionReport report) {
    if (_requesting.contains(group)) return PermissionState.requesting;
    return switch (report.statusOf(group)) {
      PermissionStatus.granted => PermissionState.granted,
      PermissionStatus.notRequired => PermissionState.notRequired,
      PermissionStatus.notRequested => PermissionState.notRequested,
      PermissionStatus.permanentlyDenied => PermissionState.permanentlyDenied,
      PermissionStatus.denied =>
        report.needsRationale(group)
            ? PermissionState.rationaleRequired
            : PermissionState.deniedRequestable,
      PermissionStatus.unknown => PermissionState.unknown,
    };
  }

  /// The permission group [feature] needs on [sdk], or null for none.
  static PermissionGroup? groupFor(VayuFeature feature, int sdk) =>
      switch (feature) {
        VayuFeature.findPhones => PermissionGroup.nearby,
        // Before Android 12 the direct connection uses the same location
        // permission as Bluetooth scanning.
        VayuFeature.directWifi =>
          sdk < 31 ? PermissionGroup.nearby : PermissionGroup.directWifi,
        VayuFeature.scanCode => PermissionGroup.camera,
        VayuFeature.chatNotifications => PermissionGroup.notifications,
        VayuFeature.transferNotifications => PermissionGroup.notifications,
        VayuFeature.saveToDownloads => PermissionGroup.storage,
      };

  /// Everything missing for [feature] in [report], permission first (on
  /// Android 12+ Bluetooth cannot be switched on without it).
  List<Blocker> blockersFor(VayuFeature feature, PermissionReport report) {
    final sdk = report.sdkVersion ?? 0;
    final blockers = <Blocker>[];

    if (feature == VayuFeature.findPhones &&
        report.bluetooth == SwitchState.unsupported) {
      return const [Blocker.switchOff(BlockerKind.unsupported)];
    }

    final group = groupFor(feature, sdk);
    if (group != null) {
      final state = stateOf(group, report);
      if (state != PermissionState.granted &&
          state != PermissionState.notRequired &&
          state != PermissionState.unknown) {
        blockers.add(Blocker.permission(group, state));
      }
    }

    switch (feature) {
      case VayuFeature.findPhones:
        if (report.bluetooth == SwitchState.off) {
          blockers.add(const Blocker.switchOff(BlockerKind.bluetoothOff));
        }
        // Bluetooth scans return nothing with Location off before Android 12.
        if (sdk > 0 && sdk < 31 && report.location == SwitchState.off) {
          blockers.add(const Blocker.switchOff(BlockerKind.locationOff));
        }
      case VayuFeature.directWifi:
        if (report.wifi == SwitchState.off) {
          blockers.add(const Blocker.switchOff(BlockerKind.wifiOff));
        }
        // The report marks Location "not needed" from Android 13.
        if (report.location == SwitchState.off) {
          blockers.add(const Blocker.switchOff(BlockerKind.locationOff));
        }
      case VayuFeature.scanCode:
      case VayuFeature.chatNotifications:
      case VayuFeature.transferNotifications:
      case VayuFeature.saveToDownloads:
        break;
    }
    return blockers;
  }

  /// Shows the system dialog for [group] and returns the resulting state.
  Future<PermissionState> request(PermissionGroup group) async {
    _requesting.add(group);
    try {
      await _platform.requestPermissionGroup(group);
    } finally {
      _requesting.remove(group);
    }
    final report = await refresh();
    _notifyChanged();
    return stateOf(group, report);
  }

  /// Asks Android to switch Bluetooth on. When the phone cannot show that
  /// dialog, opens the Bluetooth settings page instead and returns false.
  Future<bool> turnOnBluetooth() async {
    final report = _last ?? await refresh();
    final sdk = report.sdkVersion ?? 0;
    // Android 12+ refuses the dialog without the Nearby devices permission.
    final canAsk =
        sdk < 31 ||
        report.statusOf(PermissionGroup.nearby) == PermissionStatus.granted;
    if (canAsk && await _platform.requestEnableBluetooth()) {
      await refresh();
      _notifyChanged();
      return true;
    }
    await _platform.openSettingsPage(SettingsPage.bluetooth);
    return false;
  }

  /// The system page that can fix [blocker].
  static SettingsPage settingsPageFor(Blocker blocker) =>
      switch (blocker.kind) {
        BlockerKind.permission =>
          blocker.group == PermissionGroup.notifications
              ? SettingsPage.notifications
              : SettingsPage.app,
        BlockerKind.bluetoothOff => SettingsPage.bluetooth,
        BlockerKind.locationOff => SettingsPage.location,
        BlockerKind.wifiOff => SettingsPage.wifi,
        BlockerKind.unsupported => SettingsPage.app,
      };

  /// Opens the page that can fix [blocker]. False if no page opened.
  Future<bool> openSettingsFor(Blocker blocker) =>
      _platform.openSettingsPage(settingsPageFor(blocker));

  /// Call when the app returns from Settings: re-reads the state and tells
  /// listeners if it changed.
  Future<PermissionReport> recheck() async {
    final report = await refresh();
    _notifyChanged();
    return report;
  }

  // Not awaited by callers: listeners may restart discovery, which takes
  // seconds. Permission screens waiting for that showed only a spinner after
  // the user had already answered.
  Future<void> _notifyChanged() async {
    final callback = onChanged;
    if (callback == null) return;
    try {
      await callback();
    } catch (_) {
      // A listener failing must not break the permission flow.
    }
  }

  /// "10" for API 29 and so on, for messages that name the Android version.
  static String androidVersionName(int sdk) => switch (sdk) {
    26 => '8',
    27 => '8.1',
    28 => '9',
    29 => '10',
    30 => '11',
    31 || 32 => '12',
    33 => '13',
    34 => '14',
    35 => '15',
    36 => '16',
    _ => '',
  };
}
