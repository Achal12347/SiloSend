import 'package:vayu/domain/identity/system_capabilities.dart';

/// Runtime permission groups Vayu asks for, each tied to one feature.
enum PermissionGroup {
  /// Bluetooth discovery and connections (Location on Android 8-11).
  nearby,

  /// Phone-to-phone Wi-Fi when there is no shared network (Android 12+).
  directWifi,

  /// Scanning Receive and pairing codes.
  camera,

  /// The progress notification of long transfers (Android 13+).
  notifications,

  /// Saving to the shared Downloads folder (Android 8-10).
  storage,
}

/// State of a system switch Vayu depends on.
enum SwitchState {
  on,
  off,
  unsupported,
  notNeeded,
  unknown;

  static SwitchState parse(Object? value) => switch (value) {
    'on' => SwitchState.on,
    'off' => SwitchState.off,
    'unsupported' => SwitchState.unsupported,
    'not_needed' => SwitchState.notNeeded,
    _ => SwitchState.unknown,
  };
}

/// System pages Vayu can open directly.
enum SettingsPage {
  app,
  notifications,
  bluetooth,
  wifi,
  location,
  nfc,
  battery,
}

/// Parses the platform's permission status strings.
PermissionStatus parsePermissionStatus(Object? value) => switch (value) {
  'granted' => PermissionStatus.granted,
  'denied' => PermissionStatus.denied,
  'permanently_denied' => PermissionStatus.permanentlyDenied,
  'not_requested' => PermissionStatus.notRequested,
  'not_needed' || 'not_required' => PermissionStatus.notRequired,
  _ => PermissionStatus.unknown,
};

/// Everything Vayu needs from the system, as reported by the platform.
class PermissionReport {
  final Map<PermissionGroup, PermissionStatus> permissions;
  final SwitchState bluetooth;
  final SwitchState wifi;
  final SwitchState location;
  final SwitchState nfc;

  /// [SwitchState.on] when Android does not restrict Vayu's battery use.
  final SwitchState battery;
  final int? sdkVersion;

  /// Groups the user refused once that Android will still ask for. Vayu
  /// explains why before asking again.
  final Set<PermissionGroup> rationale;

  /// Android 12: Location was allowed as "Approximate" only. Settings then
  /// shows it as allowed, but Wi-Fi Direct needs "Use precise location".
  final bool approximateLocationOnly;

  const PermissionReport({
    required this.permissions,
    required this.bluetooth,
    required this.wifi,
    required this.location,
    required this.nfc,
    required this.battery,
    this.sdkVersion,
    this.rationale = const {},
    this.approximateLocationOnly = false,
  });

  /// A platform with nothing to grant (desktop, tests).
  factory PermissionReport.notApplicable() => PermissionReport(
    permissions: {
      for (final group in PermissionGroup.values)
        group: PermissionStatus.notRequired,
    },
    bluetooth: SwitchState.notNeeded,
    wifi: SwitchState.notNeeded,
    location: SwitchState.notNeeded,
    nfc: SwitchState.notNeeded,
    battery: SwitchState.notNeeded,
  );

  factory PermissionReport.fromMap(Map<dynamic, dynamic> map) =>
      PermissionReport(
        permissions: {
          for (final group in PermissionGroup.values)
            group: parsePermissionStatus(map[group.name]),
        },
        bluetooth: SwitchState.parse(map['bluetooth']),
        wifi: SwitchState.parse(map['wifi']),
        location: SwitchState.parse(map['location']),
        nfc: SwitchState.parse(map['nfc']),
        battery: SwitchState.parse(map['battery']),
        sdkVersion: map['sdkVersion'] as int?,
        rationale: {
          for (final name in (map['rationale'] as List?) ?? const [])
            for (final group in PermissionGroup.values)
              if (group.name == name) group,
        },
        approximateLocationOnly: map['approximateLocationOnly'] == true,
      );

  PermissionStatus statusOf(PermissionGroup group) =>
      permissions[group] ?? PermissionStatus.unknown;

  /// Whether [group] was refused once and can still be asked for.
  bool needsRationale(PermissionGroup group) => rationale.contains(group);
}
