import 'package:flutter/material.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/platform/qr_scanner.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/widgets/camera_access.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Lets the user choose one device in a bottom sheet: a nearby phone from
/// the list, or any phone on its Receive screen by scanning its QR code.
/// Returns null if none is chosen.
Future<DiscoveredPeer?> pickNearbyPeer(
  BuildContext context, {
  required AppContainer container,
  required String title,
}) {
  return showVayuSheet<DiscoveredPeer>(
    context: context,
    builder: (_) => _PeerPickerSheet(container: container, title: title),
  );
}

class _PeerPickerSheet extends StatefulWidget {
  final AppContainer container;
  final String title;

  const _PeerPickerSheet({required this.container, required this.title});

  @override
  State<_PeerPickerSheet> createState() => _PeerPickerSheetState();
}

class _PeerPickerSheetState extends State<_PeerPickerSheet> {
  bool _joining = false;

  Future<void> _scan() async {
    final c = widget.container;
    if (!await ensureCameraAccess(context, c)) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _joining = true);
    try {
      final text = await const QrScanner().scan();
      if (text == null || !mounted) return;
      final peer = await c.pairingCoordinator.joinToSendFromText(text);
      if (mounted) Navigator.of(context).pop(peer);
    } on QrScanException {
      showVayuNotice(
        null,
        'The camera could not be opened.',
        messenger: messenger,
        tone: VayuNoticeTone.problem,
      );
    } on PairingException catch (e) {
      showVayuNotice(
        null,
        e.message,
        messenger: messenger,
        tone: VayuNoticeTone.problem,
      );
    } catch (e) {
      showVayuNotice(
        null,
        friendlyError(e),
        messenger: messenger,
        tone: VayuNoticeTone.problem,
      );
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<DiscoveredPeer>>(
      stream: widget.container.discoveredPeersStream,
      initialData: widget.container.discoveredPeers,
      builder: (context, snapshot) {
        final peers = snapshot.data ?? const <DiscoveredPeer>[];
        return VayuSheet(
          title: widget.title,
          content: peers.isEmpty
              ? Text(
                  'No phones nearby yet. Scan the code on the other '
                  "phone's Receive screen, or open Vayu on it.",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              : Column(
                  children: [
                    for (final p in peers)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: DeviceAvatar(
                          name: p.displayName,
                          seed: p.deviceId,
                        ),
                        title: Text(p.displayName),
                        enabled: !_joining,
                        onTap: () => Navigator.of(context).pop(p),
                      ),
                  ],
                ),
          actions: [
            FilledButton.tonalIcon(
              onPressed: _joining ? null : _scan,
              icon: _joining
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.qr_code_scanner_rounded, size: 18),
              label: Text(_joining ? 'Connecting…' : 'Scan QR'),
            ),
          ],
        );
      },
    );
  }
}
