import 'package:flutter/material.dart';

import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/widgets/permission_flow.dart';

/// Makes sure the camera may be used before opening the code scanner.
///
/// The user just tapped Scan, so the first dialog needs no explanation. If
/// they refuse, a sheet explains; when Android no longer shows the dialog it
/// sends them to Vayu's settings page and continues once they come back.
/// Returns true when the scanner can open.
Future<bool> ensureCameraAccess(BuildContext context, AppContainer container) =>
    ensureFeature(
      context,
      container,
      VayuFeature.scanCode,
      alreadyExplained: true,
    );
