import 'package:flutter/material.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Lets the user choose one nearby device in a bottom sheet. Returns null if
/// none is chosen, and explains when no device is nearby yet.
Future<DiscoveredPeer?> pickNearbyPeer(
  BuildContext context, {
  required AppContainer container,
  required String title,
}) async {
  final peers = container.discoveredPeers;
  if (peers.isEmpty) {
    showVayuNotice(
      context,
      'No phones nearby yet. Open Vayu on the other phone first.',
    );
    return null;
  }
  return showVayuSheet<DiscoveredPeer>(
    context: context,
    builder: (sheetContext) => VayuSheet(
      title: title,
      content: Column(
        children: [
          for (final p in peers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: DeviceAvatar(name: p.displayName, seed: p.deviceId),
              title: Text(p.displayName),
              onTap: () => Navigator.of(sheetContext).pop(p),
            ),
        ],
      ),
    ),
  );
}
