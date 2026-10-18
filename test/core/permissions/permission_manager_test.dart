import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/platform/platform_service.dart';

class _FakePlatform extends PlatformService {
  PermissionReport report;
  final requested = <PermissionGroup>[];
  final opened = <SettingsPage>[];
  int enableBluetoothCalls = 0;
  bool enableBluetoothResult = true;

  /// When set, requests wait for it (to look at the state mid-dialog).
  Completer<void>? dialog;

  /// The report after the user answers.
  PermissionReport Function()? afterAnswer;

  _FakePlatform(this.report);

  @override
  String get platformName => 'android';

  @override
  Future<DeviceCapabilities> getCapabilities() async =>
      const DeviceCapabilities.fromBooleans(
        supportsBle: true,
        supportsBleAdvertising: true,
        supportsWifiDirect: true,
        supportsNfc: true,
        hasCamera: true,
      );

  @override
  Future<bool> isBleSupported() async => true;

  @override
  Future<bool> isWifiDirectSupported() async => true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<PermissionReport> permissionReport() async => report;

  @override
  Future<PermissionStatus> requestPermissionGroup(PermissionGroup group) async {
    requested.add(group);
    await dialog?.future;
    final next = afterAnswer;
    if (next != null) report = next();
    return report.statusOf(group);
  }

  @override
  Future<bool> requestEnableBluetooth() async {
    enableBluetoothCalls++;
    return enableBluetoothResult;
  }

  @override
  Future<bool> openSettingsPage(SettingsPage page) async {
    opened.add(page);
    return true;
  }
}

PermissionReport report({
  required int sdk,
  PermissionStatus nearby = PermissionStatus.granted,
  PermissionStatus directWifi = PermissionStatus.granted,
  PermissionStatus camera = PermissionStatus.granted,
  PermissionStatus notifications = PermissionStatus.granted,
  PermissionStatus storage = PermissionStatus.notRequired,
  SwitchState bluetooth = SwitchState.on,
  SwitchState wifi = SwitchState.on,
  SwitchState? location,
  Set<PermissionGroup> rationale = const {},
}) => PermissionReport(
  permissions: {
    PermissionGroup.nearby: nearby,
    PermissionGroup.directWifi: directWifi,
    PermissionGroup.camera: camera,
    PermissionGroup.notifications: notifications,
    PermissionGroup.storage: storage,
  },
  bluetooth: bluetooth,
  wifi: wifi,
  location: location ?? (sdk < 33 ? SwitchState.on : SwitchState.notNeeded),
  nfc: SwitchState.on,
  battery: SwitchState.on,
  sdkVersion: sdk,
  rationale: rationale,
);

void main() {
  PermissionManager managerFor(PermissionReport r) =>
      PermissionManager(_FakePlatform(r));

  group('what each feature needs', () {
    test('nothing missing means ready', () {
      final m = managerFor(report(sdk: 34));
      for (final feature in VayuFeature.values) {
        expect(
          m.blockersFor(feature, report(sdk: 34)),
          isEmpty,
          reason: '$feature',
        );
      }
    });

    test('a platform with nothing to grant is always ready', () {
      final m = managerFor(PermissionReport.notApplicable());
      for (final feature in VayuFeature.values) {
        expect(
          m.blockersFor(feature, PermissionReport.notApplicable()),
          isEmpty,
        );
      }
    });

    test('Android 10: Location off blocks Bluetooth discovery', () {
      final r = report(sdk: 29, location: SwitchState.off);
      final blockers = managerFor(r).blockersFor(VayuFeature.findPhones, r);
      expect(blockers.single.kind, BlockerKind.locationOff);
    });

    test('Android 12: Location off does not block Bluetooth discovery', () {
      final r = report(sdk: 31, location: SwitchState.off);
      expect(managerFor(r).blockersFor(VayuFeature.findPhones, r), isEmpty);
    });

    test('Android 12: Location off still blocks a direct connection', () {
      final r = report(sdk: 31, location: SwitchState.off);
      final blockers = managerFor(r).blockersFor(VayuFeature.directWifi, r);
      expect(blockers.single.kind, BlockerKind.locationOff);
    });

    test('Android 13+: Location is never asked for', () {
      final r = report(sdk: 33);
      expect(r.location, SwitchState.notNeeded);
      expect(managerFor(r).blockersFor(VayuFeature.directWifi, r), isEmpty);
    });

    test('before Android 12 the direct connection uses the nearby group', () {
      final r = report(
        sdk: 29,
        nearby: PermissionStatus.notRequested,
        directWifi: PermissionStatus.notRequired,
      );
      final blocker = managerFor(r)
          .blockersFor(VayuFeature.directWifi, r)
          .single;
      expect(blocker.group, PermissionGroup.nearby);
      expect(blocker.state, PermissionState.notRequested);
    });

    test('Android 13+ uses Nearby Wi-Fi devices for a direct connection', () {
      final r = report(sdk: 34, directWifi: PermissionStatus.denied);
      final blocker = managerFor(r)
          .blockersFor(VayuFeature.directWifi, r)
          .single;
      expect(blocker.group, PermissionGroup.directWifi);
    });

    test('permission comes before switching Bluetooth on', () {
      final r = report(
        sdk: 34,
        nearby: PermissionStatus.notRequested,
        bluetooth: SwitchState.off,
      );
      final kinds = managerFor(r)
          .blockersFor(VayuFeature.findPhones, r)
          .map((b) => b.kind);
      expect(kinds, [BlockerKind.permission, BlockerKind.bluetoothOff]);
    });

    test('Wi-Fi off blocks a direct connection', () {
      final r = report(sdk: 34, wifi: SwitchState.off);
      expect(
        managerFor(r).blockersFor(VayuFeature.directWifi, r).single.kind,
        BlockerKind.wifiOff,
      );
    });

    test(
      'no Bluetooth hardware is reported as unsupported, not as a prompt',
      () {
        final r = report(
          sdk: 34,
          nearby: PermissionStatus.notRequested,
          bluetooth: SwitchState.unsupported,
        );
        expect(
          managerFor(r).blockersFor(VayuFeature.findPhones, r).single.kind,
          BlockerKind.unsupported,
        );
      },
    );

    test(
      'an unknown state does not block (the action reports its own error)',
      () {
        final r = report(sdk: 34, camera: PermissionStatus.unknown);
        expect(managerFor(r).blockersFor(VayuFeature.scanCode, r), isEmpty);
      },
    );
  });

  group('permission states', () {
    test('refused once with a rationale vs plain refusal vs blocked', () {
      final r = report(
        sdk: 34,
        camera: PermissionStatus.denied,
        notifications: PermissionStatus.denied,
        nearby: PermissionStatus.permanentlyDenied,
        rationale: {PermissionGroup.camera},
      );
      final m = managerFor(r);
      expect(
        m.stateOf(PermissionGroup.camera, r),
        PermissionState.rationaleRequired,
      );
      expect(
        m.stateOf(PermissionGroup.notifications, r),
        PermissionState.deniedRequestable,
      );
      expect(
        m.stateOf(PermissionGroup.nearby, r),
        PermissionState.permanentlyDenied,
      );
      expect(
        m.stateOf(PermissionGroup.storage, r),
        PermissionState.notRequired,
      );
    });

    test('blocked permissions cannot be asked for again', () {
      expect(
        const Blocker.permission(
          PermissionGroup.camera,
          PermissionState.permanentlyDenied,
        ).canAsk,
        isFalse,
      );
      expect(
        const Blocker.permission(
          PermissionGroup.camera,
          PermissionState.rationaleRequired,
        ).canAsk,
        isTrue,
      );
    });

    test('a request reports "requesting" while the dialog shows', () async {
      final platform = _FakePlatform(
        report(sdk: 34, camera: PermissionStatus.notRequested),
      )..dialog = Completer<void>();
      platform.afterAnswer = () => report(sdk: 34);
      var changes = 0;
      final m = PermissionManager(platform, onChanged: () async => changes++);

      final pending = m.request(PermissionGroup.camera);
      await Future<void>.delayed(Duration.zero);
      expect(
        m.stateOf(PermissionGroup.camera, platform.report),
        PermissionState.requesting,
      );

      platform.dialog!.complete();
      expect(await pending, PermissionState.granted);
      expect(changes, 1);
    });
  });

  group('fixing switches', () {
    test(
      'Android 12+ without Nearby devices opens Bluetooth settings',
      () async {
        final platform = _FakePlatform(
          report(
            sdk: 31,
            nearby: PermissionStatus.denied,
            bluetooth: SwitchState.off,
          ),
        );
        final m = PermissionManager(platform);
        expect(await m.turnOnBluetooth(), isFalse);
        expect(platform.enableBluetoothCalls, 0);
        expect(platform.opened, [SettingsPage.bluetooth]);
      },
    );

    test(
      'Android 10 shows the Bluetooth dialog without any permission',
      () async {
        final platform = _FakePlatform(
          report(
            sdk: 29,
            nearby: PermissionStatus.notRequested,
            bluetooth: SwitchState.off,
          ),
        );
        expect(await PermissionManager(platform).turnOnBluetooth(), isTrue);
        expect(platform.enableBluetoothCalls, 1);
        expect(platform.opened, isEmpty);
      },
    );

    test('each blocker opens its exact settings page', () {
      expect(
        PermissionManager.settingsPageFor(
          const Blocker.permission(
            PermissionGroup.notifications,
            PermissionState.permanentlyDenied,
          ),
        ),
        SettingsPage.notifications,
      );
      expect(
        PermissionManager.settingsPageFor(
          const Blocker.permission(
            PermissionGroup.camera,
            PermissionState.permanentlyDenied,
          ),
        ),
        SettingsPage.app,
      );
      expect(
        PermissionManager.settingsPageFor(
          const Blocker.switchOff(BlockerKind.locationOff),
        ),
        SettingsPage.location,
      );
      expect(
        PermissionManager.settingsPageFor(
          const Blocker.switchOff(BlockerKind.wifiOff),
        ),
        SettingsPage.wifi,
      );
    });
  });
}
