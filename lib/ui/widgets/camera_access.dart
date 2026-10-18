import 'package:flutter/material.dart';

import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Makes sure the camera may be used before opening the code scanner.
///
/// The request goes through the same queue as every other permission, so it
/// never collides with another dialog. When Android no longer shows the
/// dialog, the notice offers Vayu's settings page. Returns true when the
/// scanner can open.
Future<bool> ensureCameraAccess(
  BuildContext context,
  AppContainer container,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final status = await container.platformService.requestPermissionGroup(
    PermissionGroup.camera,
  );
  if (status == PermissionStatus.granted ||
      status == PermissionStatus.notRequired ||
      status == PermissionStatus.unknown) {
    return true;
  }
  if (!context.mounted) return false;
  final blocked = status == PermissionStatus.permanentlyDenied;
  showVayuNotice(
    context,
    blocked
        ? 'Camera is blocked for Vayu. Allow it in settings to scan.'
        : 'Vayu needs the camera to scan the code.',
    messenger: messenger,
    tone: VayuNoticeTone.problem,
    actionLabel: blocked ? 'Settings' : null,
    onAction: blocked
        ? () => container.platformService.openSettingsPage(SettingsPage.app)
        : null,
  );
  return false;
}
