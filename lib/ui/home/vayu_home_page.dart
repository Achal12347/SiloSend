import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:vayu/core/capabilities/capability_coordinator.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_orchestrator.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/ui/connection/active_connections_card.dart';
import 'package:vayu/ui/home/capability_setup_banner.dart';
import 'package:vayu/ui/home/discovered_peer_card.dart';
import 'package:vayu/ui/home/local_device_card.dart';
import 'package:vayu/ui/pairing/pairing_page.dart';
import 'package:vayu/platform/contact_picker.dart';
import 'package:vayu/platform/share_intent_service.dart';
import 'package:vayu/ui/settings/settings_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/incoming_batch_dialog.dart';
import 'package:vayu/ui/transfer/incoming_transfer_dialog.dart';
import 'package:vayu/ui/transfer/peer_selection_sheet.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/transfer/transfer_progress_card.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Primary Home screen.
///
/// Reads top to bottom as the user's task: share (hero), who is nearby, what is
/// moving, and who you appear as. Protocol details (device IDs, fingerprints,
/// session internals) live in Diagnostics, not here.
class VayuHomePage extends StatefulWidget {
  const VayuHomePage({super.key});

  @override
  State<VayuHomePage> createState() => _VayuHomePageState();
}

class _VayuHomePageState extends State<VayuHomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  bool _isTogglingDiscovery = false;
  bool _isPickingHeroFile = false;
  final Set<String> _connectingPeerIds = {};
  StreamSubscription<IncomingTransferRequest>? _incomingRequestsSub;
  StreamSubscription<IncomingBatchRequest>? _incomingBatchesSub;
  ShareIntentService? _shareIntents;
  StreamSubscription<List<SelectedDocument>>? _sharedSub;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    final isTesting =
        Platform.environment.containsKey('FLUTTER_TEST') ||
        WidgetsBinding.instance.runtimeType.toString().contains('Test');
    if (!isTesting) {
      _pulseController.repeat();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoStartDiscoveryIfReady();
      if (Platform.isAndroid && !isTesting) _listenForSharedFiles();
    });
  }

  /// "Share to Vayu" from other apps lands here: go straight to device choice.
  Future<void> _listenForSharedFiles() async {
    final shares = ShareIntentService();
    _shareIntents = shares;
    _sharedSub = shares.incoming.listen(_offerShared);
    _offerShared(await shares.takePending());
  }

  Future<void> _offerShared(List<SelectedDocument> docs) async {
    if (docs.isEmpty || !mounted) return;
    await PeerSelectionSheet.show(
      context,
      documents: docs,
      container: AppScope.of(context),
    );
  }

  Future<void> _autoStartDiscoveryIfReady() async {
    if (!mounted) return;
    final container = AppScope.of(context);
    try {
      final raw = container.capabilityCoordinator.rawCapabilities;
      if (raw.isNearbyPermissionNotRequested) {
        await container.capabilityCoordinator.requestNearbyAccess();
      }
      if (container.capabilityCoordinator.state.hasAnyReady &&
          container.discoveryStatus == DiscoveryStatus.idle) {
        await container.startDiscoveryAndAdvertising();
      }
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final container = AppScope.of(context);
    _incomingRequestsSub?.cancel();
    _incomingRequestsSub = container.incomingTransferRequests.listen((request) {
      if (mounted) {
        IncomingTransferDialog.show(
          context,
          request: request,
          container: container,
        );
      }
    });
    _incomingBatchesSub?.cancel();
    _incomingBatchesSub = container.incomingBatchRequests.listen((request) {
      if (mounted) {
        IncomingBatchDialog.show(
          context,
          request: request,
          container: container,
        );
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _incomingRequestsSub?.cancel();
    _incomingBatchesSub?.cancel();
    _sharedSub?.cancel();
    _shareIntents?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final container = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const _Wordmark(),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_2_rounded),
            tooltip: 'Pair with QR or NFC',
            onPressed: () => PairingPage.open(context, container),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => SettingsPage(container: container),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => container.capabilityCoordinator.refresh(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              _buildHero(context, container),
              const SizedBox(height: 16),
              CapabilitySetupBanner(container: container),
              _buildNearbySection(context, container),
              const SizedBox(height: 24),
              TransferProgressCard(container: container),
              _buildConnectionsIfAny(container),
              LocalDeviceCard(container: container),
              const SizedBox(height: 24),
              _buildFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------- hero

  Widget _buildHero(BuildContext context, AppContainer container) {
    final palette = VayuPalette.of(context);
    final theme = Theme.of(context);

    // Ink card with a soft sage glow: depth from tone, not from saturated color.
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: palette.heroGradient,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: palette.heroBorder),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -60,
            top: -80,
            child: IgnorePointer(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      palette.heroGlow.withValues(alpha: 0.32),
                      palette.heroGlow.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ReadinessLine(container: container, color: palette.onHero),
                const SizedBox(height: 14),
                Text(
                  'Share files nearby',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: palette.onHero,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Direct and encrypted. No internet needed.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: palette.onHeroMuted,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: _isPickingHeroFile
                        ? null
                        : () => _onHeroSendFilePressed(container),
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.onHero,
                      foregroundColor: const Color(0xFF1A1B1E),
                      disabledBackgroundColor: palette.onHero.withValues(
                        alpha: 0.6,
                      ),
                      textStyle: theme.textTheme.titleMedium,
                    ),
                    icon: _isPickingHeroFile
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : const Icon(Icons.north_east_rounded),
                    label: Text(
                      _isPickingHeroFile ? 'Choosing files…' : 'Send files',
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: TextButton.icon(
                    onPressed: () => _shareContactFromHero(container),
                    style: TextButton.styleFrom(
                      foregroundColor: palette.onHeroMuted,
                    ),
                    icon: const Icon(Icons.person_outline_rounded, size: 18),
                    label: const Text('Share a contact'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ nearby

  Widget _buildNearbySection(BuildContext context, AppContainer container) {
    final theme = Theme.of(context);
    return StreamBuilder<DiscoveryStatus>(
      stream: container.discoveryStatusStream,
      initialData: container.discoveryStatus,
      builder: (context, statusSnapshot) {
        final isScanning =
            (statusSnapshot.data ?? DiscoveryStatus.idle).isActive;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Nearby devices',
              leading: _ScanIndicator(
                active: isScanning,
                animation: _pulseController,
              ),
              trailing: TextButton(
                onPressed: _isTogglingDiscovery
                    ? null
                    : () => _toggleDiscovery(container, isScanning),
                child: Text(isScanning ? 'Stop' : 'Search'),
              ),
            ),
            if (isScanning)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Text(
                  _scanningLabel(container),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            StreamBuilder<List<DiscoveredPeer>>(
              stream: container.discoveredPeersStream,
              initialData: container.discoveredPeers,
              builder: (context, peerSnapshot) {
                final peers = peerSnapshot.data ?? [];
                return StreamBuilder<DiscoveryOperationalState>(
                  stream: container.discoveryCoordinator.operationalStateStream,
                  initialData: container.discoveryCoordinator.operationalState,
                  builder: (context, opSnapshot) {
                    if (peers.isNotEmpty) {
                      return Card(
                        child: Column(
                          children: [
                            for (var i = 0; i < peers.length; i++) ...[
                              if (i > 0)
                                const Divider(indent: 72, endIndent: 16),
                              DiscoveredPeerCard(
                                container: container,
                                peer: peers[i],
                                isConnecting: _connectingPeerIds.contains(
                                  peers[i].deviceId,
                                ),
                                onConnectPressed: () =>
                                    _connectToPeer(container, peers[i]),
                                onSendFilePressed: () =>
                                    _sendFileToPeerDirect(container, peers[i]),
                                onSendContactPressed: () =>
                                    _sendContactTo(container, peers[i]),
                              ),
                            ],
                          ],
                        ),
                      );
                    }
                    return _buildEmptyNearby(
                      context,
                      container,
                      isScanning: isScanning,
                      opState:
                          opSnapshot.data ??
                          container.discoveryCoordinator.operationalState,
                    );
                  },
                );
              },
            ),
          ],
        );
      },
    );
  }

  String _scanningLabel(AppContainer container) {
    final active = container.discoveryCoordinator.activeTransports;
    final hasLan = active.contains(TransportType.lan);
    final hasBle = active.contains(TransportType.ble);
    if (hasLan && hasBle) return 'Looking on Wi-Fi and Bluetooth';
    if (hasLan) return 'Looking on Wi-Fi';
    if (hasBle) return 'Looking on Bluetooth';
    return 'Starting radios…';
  }

  Widget _buildEmptyNearby(
    BuildContext context,
    AppContainer container, {
    required bool isScanning,
    required DiscoveryOperationalState opState,
  }) {
    final theme = Theme.of(context);
    final IconData icon;
    final String title;
    final String body;
    Widget? action;

    if (!isScanning) {
      icon = Icons.wifi_tethering_off_rounded;
      title = 'Search is paused';
      body = 'Start searching to find phones with Vayu open nearby.';
      action = FilledButton.tonalIcon(
        onPressed: () => _toggleDiscovery(container, false),
        icon: const Icon(Icons.search_rounded),
        label: const Text('Start searching'),
      );
    } else if (opState == DiscoveryOperationalState.noDevices) {
      icon = Icons.devices_other_rounded;
      title = 'No devices found yet';
      body = 'Open Vayu on the other phone and keep both on the same Wi-Fi, or turn on Bluetooth.';
      action = OutlinedButton.icon(
        onPressed: () async {
          await _toggleDiscovery(container, true);
          await _toggleDiscovery(container, false);
        },
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Search again'),
      );
    } else {
      icon = Icons.radar_rounded;
      title = 'Searching for nearby devices…';
      body = 'Phones with Vayu open will appear here.';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primaryContainer,
              ),
              child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- connections

  /// Live sessions matter only when they exist; an empty "no connections"
  /// card mostly exposed protocol vocabulary.
  Widget _buildConnectionsIfAny(AppContainer container) {
    return StreamBuilder<List<ConnectionSession>>(
      stream: container.activeSessionsStream,
      initialData: container.activeSessions,
      builder: (context, snapshot) {
        if ((snapshot.data ?? const []).isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: ActiveConnectionsCard(container: container),
        );
      },
    );
  }

  Widget _buildFooter(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          'End-to-end encrypted · Works offline',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- actions

  /// Hero flow: system file picker, then choose a nearby device.
  Future<void> _onHeroSendFilePressed(AppContainer container) async {
    setState(() => _isPickingHeroFile = true);
    try {
      final raw = container.capabilityCoordinator.rawCapabilities;
      if (raw.isNearbyPermissionNotRequested) {
        await container.capabilityCoordinator.requestNearbyAccess();
      }

      final docs = await container.filePickerService.pickMultipleDocuments();
      if (docs.isNotEmpty && mounted) {
        await PeerSelectionSheet.show(
          context,
          documents: docs,
          container: container,
        );
      }
    } catch (e) {
      if (mounted) {
        _showError('Could not open files: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingHeroFile = false);
      }
    }
  }

  Future<void> _toggleDiscovery(
    AppContainer container,
    bool isCurrentlyScanning,
  ) async {
    setState(() => _isTogglingDiscovery = true);
    try {
      if (isCurrentlyScanning) {
        await container.stopDiscoveryAndAdvertising();
      } else {
        final raw = container.capabilityCoordinator.rawCapabilities;
        if (raw.isNearbyPermissionNotRequested ||
            (raw.isNearbyPermissionMissing && !raw.canUseLan)) {
          final status = await container.capabilityCoordinator
              .requestNearbyAccess();
          if (status.isPermanentlyDenied) {
            await container.capabilityCoordinator.openAppSettings();
          }
        }
        await container.startDiscoveryAndAdvertising();
      }
    } catch (error) {
      if (mounted) {
        _showError(error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() => _isTogglingDiscovery = false);
      }
    }
  }

  Future<void> _connectToPeer(
    AppContainer container,
    DiscoveredPeer peer,
  ) async {
    setState(() => _connectingPeerIds.add(peer.deviceId));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await container.connectToPeer(peer);
      messenger.showSnackBar(
        SnackBar(content: Text('Connected to ${peer.displayName}')),
      );
    } catch (e) {
      if (mounted) {
        _showError(
          'Could not reach ${peer.displayName}. Move closer and try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _connectingPeerIds.remove(peer.deviceId));
      }
    }
  }

  Future<void> _sendFileToPeerDirect(
    AppContainer container,
    DiscoveredPeer peer,
  ) async {
    try {
      final task = await container.fileSharingCoordinator.sendFileToPeer(peer);
      if (task != null && mounted) {
        await TransferDetailPage.open(
          context,
          container,
          transferId: task.transferId,
        );
      }
    } catch (e) {
      if (mounted) {
        _showError('Could not send to ${peer.displayName}: $e');
      }
    }
  }

  /// Picks one contact with the system picker; null when the user backs out.
  Future<PickedContact?> _pickContact() async {
    try {
      return await const ContactPicker().pick();
    } on ContactPickerException catch (e) {
      if (mounted) {
        _showError(
          e.isPermissionDenied
              ? 'Vayu needs access to the contact you choose to share it.'
              : 'Could not open contacts.',
        );
      }
      return null;
    }
  }

  Future<void> _sendContactTo(
    AppContainer container,
    DiscoveredPeer peer,
  ) async {
    final contact = await _pickContact();
    if (contact == null || !mounted) return;
    try {
      final task = await container.fileSharingCoordinator.sendContactToPeer(
        peer,
        name: contact.name,
        vcard: contact.vcard,
      );
      if (mounted) {
        await TransferDetailPage.open(context, container, task: task);
      }
    } catch (e) {
      if (mounted) _showError('Could not send the contact: $e');
    }
  }

  /// Hero flow for contacts: pick the contact first, then the device.
  Future<void> _shareContactFromHero(AppContainer container) async {
    final contact = await _pickContact();
    if (contact == null || !mounted) return;
    final peers = container.discoveredPeers;
    if (peers.isEmpty) {
      _showError('No nearby devices yet. Open Vayu on the other phone first.');
      return;
    }
    final peer = await showModalBottomSheet<DiscoveredPeer>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Send ${contact.name} to',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final p in peers)
              ListTile(
                leading: DeviceAvatar(name: p.displayName, seed: p.deviceId),
                title: Text(p.displayName),
                onTap: () => Navigator.of(sheetContext).pop(p),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (peer != null && mounted) {
      try {
        final task = await container.fileSharingCoordinator.sendContactToPeer(
          peer,
          name: contact.name,
          vcard: contact.vcard,
        );
        if (mounted) {
          await TransferDetailPage.open(context, container, task: task);
        }
      } catch (e) {
        if (mounted) _showError('Could not send the contact: $e');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: VayuPalette.of(context).danger,
      ),
    );
  }
}

/// App name with a small wind mark, used as the home title.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            gradient: palette.heroGradient,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.air_rounded, color: palette.heroGlow, size: 20),
        ),
        const SizedBox(width: 10),
        Text(
          AppConstants.appName,
          style: theme.textTheme.titleLarge?.copyWith(letterSpacing: -0.4),
        ),
      ],
    );
  }
}

/// One-line live readiness shown on the hero, plus Battery Saver when active.
class _ReadinessLine extends StatelessWidget {
  final AppContainer container;
  final Color color;

  const _ReadinessLine({required this.container, required this.color});

  @override
  Widget build(BuildContext context) {
    final palette = VayuPalette.of(context);
    return StreamBuilder<EvaluatedCapabilityState>(
      stream: container.capabilityCoordinator.stateStream,
      initialData: container.capabilityCoordinator.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? container.capabilityCoordinator.state;
        final (String label, IconData icon) = switch (state.operationalStatus) {
          CapabilityOperationalStatus.readyBoth => (
            'Ready · Wi-Fi + Bluetooth',
            Icons.check_circle_rounded,
          ),
          CapabilityOperationalStatus.readyLanOnly => (
            'Ready · Wi-Fi',
            Icons.check_circle_rounded,
          ),
          CapabilityOperationalStatus.readyBleOnly => (
            'Ready · Bluetooth',
            Icons.check_circle_rounded,
          ),
          CapabilityOperationalStatus.checking => (
            'Checking connectivity…',
            Icons.hourglass_top_rounded,
          ),
          CapabilityOperationalStatus.actionRequired => (
            'Setup needed',
            Icons.error_outline_rounded,
          ),
        };

        return StreamBuilder<AppOrchestratorState>(
          stream: container.orchestratorStateStream,
          initialData: container.orchestrator.currentState,
          builder: (context, orchestrator) {
            final saver = orchestrator.data?.isBatterySaverActive ?? false;
            return Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                StatusPill(
                  label: label,
                  icon: icon,
                  foreground: color,
                  background: palette.onHero.withValues(alpha: 0.08),
                ),
                if (saver)
                  StatusPill(
                    label: 'Battery Saver',
                    icon: Icons.battery_saver_rounded,
                    foreground: color,
                    background: palette.onHero.withValues(alpha: 0.08),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Small breathing dot that is only animated while discovery is running.
class _ScanIndicator extends StatelessWidget {
  final bool active;
  final Animation<double> animation;

  const _ScanIndicator({required this.active, required this.animation});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active
        ? theme.colorScheme.secondary
        : theme.colorScheme.outline;
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = active ? animation.value : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (active)
                Container(
                  width: 6 + 8 * t,
                  height: 6 + 8 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.35 * (1 - t)),
                  ),
                ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            ],
          );
        },
      ),
    );
  }
}
