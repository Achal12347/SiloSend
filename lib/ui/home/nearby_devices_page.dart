import 'package:flutter/material.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/home/discovered_peer_card.dart';
import 'package:vayu/ui/chats/conversation_page.dart';
import 'package:vayu/ui/widgets/permission_flow.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Every phone Vayu has found nearby, with how it was found.
///
/// Filters use only what discovery really reported (a Wi-Fi or Bluetooth
/// address); signal strength, distance and hop counts are not shown because
/// Vayu does not measure them.
class NearbyDevicesPage extends StatefulWidget {
  final AppContainer container;

  const NearbyDevicesPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NearbyDevicesPage(container: container),
        ),
      );

  @override
  State<NearbyDevicesPage> createState() => _NearbyDevicesPageState();
}

enum _Filter { all, wifi, bluetooth }

class _NearbyDevicesPageState extends State<NearbyDevicesPage> {
  _Filter _filter = _Filter.all;
  bool _toggling = false;

  AppContainer get _c => widget.container;

  @override
  void initState() {
    super.initState();
    // Looking at this page means looking for phones.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.holdDiscovery(this);
    });
  }

  @override
  void dispose() {
    try {
      _c.releaseDiscovery(this);
    } on StateError {
      // The container was already disposed (app shutdown).
    }
    super.dispose();
  }

  bool _matches(DiscoveredPeer peer) => switch (_filter) {
    _Filter.all => true,
    _Filter.wifi => peer.lanEndpoint != null,
    _Filter.bluetooth => peer.bleEndpoint != null,
  };

  Future<void> _toggleSearch(bool searching) async {
    setState(() => _toggling = true);
    try {
      if (searching) {
        _c.endDiscoveryWindow();
        await _c.stopDiscoveryAndAdvertising();
      } else {
        final raw = _c.capabilityCoordinator.rawCapabilities;
        if (raw.isNearbyPermissionNotRequested ||
            (raw.isNearbyPermissionMissing && !raw.canUseLan)) {
          await ensureFeature(context, _c, VayuFeature.findPhones);
        }
        await _c.startDiscoveryAndAdvertising();
        _c.discoverFor(AppContainer.discoveryWindow);
      }
    } catch (error) {
      if (mounted) {
        showVayuNotice(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
          tone: VayuNoticeTone.problem,
        );
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<DiscoveryStatus>(
      stream: _c.discoveryStatusStream,
      initialData: _c.discoveryStatus,
      builder: (context, statusSnapshot) {
        final searching =
            (statusSnapshot.data ?? DiscoveryStatus.idle).isActive;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Nearby devices'),
            actions: [
              TextButton(
                onPressed: _toggling ? null : () => _toggleSearch(searching),
                child: Text(searching ? 'Stop' : 'Search'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            child: StreamBuilder<List<DiscoveredPeer>>(
              stream: _c.discoveredPeersStream,
              initialData: _c.discoveredPeers,
              builder: (context, snapshot) {
                final peers = snapshot.data ?? const <DiscoveredPeer>[];
                final shown = peers.where(_matches).toList();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final f in _Filter.values)
                          ChoiceChip(
                            label: Text(switch (f) {
                              _Filter.all => 'All (${peers.length})',
                              _Filter.wifi => 'Wi-Fi',
                              _Filter.bluetooth => 'Bluetooth',
                            }),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 40, 8, 0),
                        child: Column(
                          children: [
                            Icon(
                              searching
                                  ? Icons.radar_rounded
                                  : Icons.wifi_tethering_off_rounded,
                              size: 40,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              searching
                                  ? (peers.isEmpty
                                        ? 'Searching… phones with Vayu open will appear here.'
                                        : 'No phones found this way yet.')
                                  : 'Search is paused. Tap Search to look for phones.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Card(
                        child: Column(
                          children: [
                            for (var i = 0; i < shown.length; i++) ...[
                              if (i > 0)
                                const Divider(indent: 72, endIndent: 16),
                              DiscoveredPeerCard(
                                container: _c,
                                peer: shown[i],
                                onChatPressed: () => ConversationPage.open(
                                  context,
                                  _c,
                                  peerDeviceId: shown[i].deviceId,
                                  peerName: shown[i].displayName,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (peers.any(
                      (p) => p.availableTransports.contains(
                        TransportType.wifiDirect,
                      ),
                    )) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Phones not on your Wi-Fi are reached over Bluetooth, '
                        'then Wi-Fi Direct for the files.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
