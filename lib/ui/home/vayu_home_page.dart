import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:vayu/core/capabilities/capability_coordinator.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/ui/connection/active_connections_card.dart';
import 'package:vayu/ui/contacts/contact_sharing_page.dart';
import 'package:vayu/ui/apps/apps_games_page.dart';
import 'package:vayu/ui/chats/conversation_page.dart';
import 'package:vayu/ui/home/capability_setup_banner.dart';
import 'package:vayu/ui/home/discovered_peer_card.dart';
import 'package:vayu/ui/home/local_device_card.dart';
import 'package:vayu/ui/home/nearby_devices_page.dart';
import 'package:vayu/ui/home/share_actions.dart';
import 'package:vayu/platform/share_intent_service.dart';
import 'package:vayu/ui/shell/primary_actions.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/incoming_batch_dialog.dart';
import 'package:vayu/ui/transfer/incoming_transfer_dialog.dart';
import 'package:vayu/ui/transfer/peer_selection_sheet.dart';
import 'package:vayu/ui/transfer/transfer_history_page.dart';
import 'package:vayu/ui/transfer/transfer_progress_card.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/profile/profile_widgets.dart';
import 'package:vayu/ui/receive/receive_page.dart';
import 'package:vayu/ui/widgets/permission_flow.dart';

/// Home: the file-sharing dashboard.
///
/// Top to bottom: what Vayu can do (Send, Receive, contacts, apps), who is
/// nearby (a short preview), and what moved recently. Protocol details live
/// in Diagnostics, not here. Also the place that listens for incoming
/// requests and items shared from other apps, which is why it stays alive
/// behind the other tabs.
class VayuHomePage extends StatefulWidget {
  const VayuHomePage({super.key});

  /// Nearby devices shown on Home; the rest are on the Nearby page.
  static const int nearbyPreviewCount = 3;

  /// Recent transfers shown on Home; View all opens the full history.
  static const int recentCount = 5;

  @override
  State<VayuHomePage> createState() => _VayuHomePageState();
}

class _VayuHomePageState extends State<VayuHomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  AppContainer? _container;

  // The scanning pulse runs only while a search is active, at most 8 s, and
  // never with Android's "Remove animations": a forever-repeating animation
  // redraws home every frame, which costs battery on low-end phones.
  StreamSubscription<DiscoveryStatus>? _statusSub;
  Timer? _pulseStop;

  void _updatePulse(bool scanning) {
    if (!mounted) return;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final isTesting = Platform.environment.containsKey('FLUTTER_TEST');
    if (scanning && !reduceMotion && !isTesting) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat();
        _pulseStop?.cancel();
        _pulseStop = Timer(const Duration(seconds: 8), () {
          if (mounted) _pulseController.stop();
        });
      }
    } else {
      _pulseStop?.cancel();
      _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  bool _isTogglingDiscovery = false;
  bool _isSending = false;
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoStartDiscoveryIfReady();
      if (Platform.isAndroid && !isTesting) {
        _listenForSharedFiles();
      }
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
      // Nearby access is asked by the setup banner or when the user starts
      // something that needs it; never unprompted here.
      // Searches for a short while, then stops to save battery.
      container.discoverFor(AppContainer.discoveryWindow);
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final container = AppScope.of(context);
    _container = container;
    if (container.isInitialized) {
      _statusSub ??= container.discoveryStatusStream.listen(
        (status) => _updatePulse(status.isActive),
      );
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _updatePulse(container.discoveryStatus.isActive),
      );
    }
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
    // Home owns its search window; nothing searches for a home that is gone.
    _container?.endDiscoveryWindow();
    _statusSub?.cancel();
    _pulseStop?.cancel();
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
        toolbarHeight: 68,
        title: _HomeTitle(container: container),
        actions: primaryAppBarActions(context, container),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await container.capabilityCoordinator.refresh();
            container.discoverFor(AppContainer.discoveryWindow);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              ProfilePromptBanner(container: container),
              _buildActions(context, container),
              const SizedBox(height: 16),
              CapabilitySetupBanner(container: container),
              TransferProgressCard(container: container),
              _buildNearbySection(context, container),
              const SizedBox(height: 24),
              _buildRecentTransfers(context, container),
              const SizedBox(height: 24),
              _buildRelayingIfAny(container),
              _buildConnectionsIfAny(container),
              // The name other phones see, with rename.
              LocalDeviceCard(container: container),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ actions

  Widget _buildActions(BuildContext context, AppContainer container) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                style: _TileStyle.primary,
                icon: Icons.north_east_rounded,
                title: 'Send',
                subtitle: 'Files & folders',
                busy: _isSending,
                onTap: _isSending ? null : () => _send(container),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionTile(
                style: _TileStyle.accent,
                icon: Icons.south_west_rounded,
                title: 'Receive',
                subtitle: 'QR & requests',
                onTap: () => ReceivePage.open(context, container),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                style: _TileStyle.plain,
                icon: Icons.contacts_outlined,
                title: 'Contact sharing',
                subtitle: 'Contacts & your card',
                onTap: () => ContactSharingPage.open(context, container),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionTile(
                style: _TileStyle.plain,
                icon: Icons.sports_esports_outlined,
                title: 'Apps & games',
                subtitle: 'Coming soon',
                badge: 'Soon',
                onTap: () => AppsGamesPage.open(context),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _send(AppContainer container) async {
    setState(() => _isSending = true);
    try {
      await ShareActions.send(context, container);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ------------------------------------------------------------------ nearby

  Widget _buildNearbySection(BuildContext context, AppContainer container) {
    return StreamBuilder<DiscoveryStatus>(
      stream: container.discoveryStatusStream,
      initialData: container.discoveryStatus,
      builder: (context, statusSnapshot) {
        final isScanning =
            (statusSnapshot.data ?? DiscoveryStatus.idle).isActive;

        return StreamBuilder<List<DiscoveredPeer>>(
          stream: container.discoveredPeersStream,
          initialData: container.discoveredPeers,
          builder: (context, peerSnapshot) {
            final peers = peerSnapshot.data ?? const <DiscoveredPeer>[];
            final shown = peers.take(VayuHomePage.nearbyPreviewCount).toList();
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
                    onPressed: () => NearbyDevicesPage.open(context, container),
                    child: Text(
                      peers.length > shown.length
                          ? 'View all (${peers.length})'
                          : 'View all',
                    ),
                  ),
                ),
                if (shown.isNotEmpty)
                  Card(
                    child: Column(
                      children: [
                        for (var i = 0; i < shown.length; i++) ...[
                          if (i > 0) const Divider(indent: 72, endIndent: 16),
                          DiscoveredPeerCard(
                            container: container,
                            peer: shown[i],
                            onChatPressed: () => ConversationPage.open(
                              context,
                              container,
                              peerDeviceId: shown[i].deviceId,
                              peerName: shown[i].displayName,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                else
                  StreamBuilder<DiscoveryOperationalState>(
                    stream:
                        container.discoveryCoordinator.operationalStateStream,
                    initialData:
                        container.discoveryCoordinator.operationalState,
                    builder: (context, opSnapshot) => _buildEmptyNearby(
                      context,
                      container,
                      isScanning: isScanning,
                      opState:
                          opSnapshot.data ??
                          container.discoveryCoordinator.operationalState,
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
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
      body = 'Vayu stops searching after 2 minutes to save battery. Search again to find phones nearby.';
      action = FilledButton.tonalIcon(
        onPressed: _isTogglingDiscovery ? null : () => _startSearch(container),
        icon: const Icon(Icons.search_rounded),
        label: const Text('Start searching'),
      );
    } else if (opState == DiscoveryOperationalState.noDevices) {
      icon = Icons.devices_other_rounded;
      title = 'No devices found yet';
      body = 'Open Vayu on the other phone.';
      action = OutlinedButton.icon(
        onPressed: _isTogglingDiscovery
            ? null
            : () async {
                container.endDiscoveryWindow();
                await container.stopDiscoveryAndAdvertising();
                await _startSearch(container);
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
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primaryContainer,
              ),
              child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (action != null) ...[const SizedBox(height: 12), action],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------- recent transfers

  Widget _buildRecentTransfers(BuildContext context, AppContainer container) {
    final theme = Theme.of(context);
    // History grows when transfers finish; the transfers stream fires then.
    return StreamBuilder<List<TransferTask>>(
      stream: container.activeTransfersStream,
      builder: (context, _) {
        final records = container.transferHistory
            .take(VayuHomePage.recentCount)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'History',
              trailing: TextButton(
                onPressed: () => TransferHistoryPage.open(context, container),
                child: const Text('View all'),
              ),
            ),
            Card(
              child: records.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'Files you send and receive will appear here.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < records.length; i++) ...[
                          if (i > 0) const Divider(indent: 72, endIndent: 16),
                          HistoryRow(
                            record: records[i],
                            onOpen: () => openHistoryRecord(
                              context,
                              container,
                              records[i],
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------------- connections

  /// Shown only while this phone relays for others (mesh), with a way to
  /// stop: the user should always see that their phone is helping.
  Widget _buildRelayingIfAny(AppContainer container) {
    final relay = container.relayService;
    if (relay == null) return const SizedBox.shrink();
    return StreamBuilder<void>(
      stream: relay.changes,
      builder: (context, _) {
        final n = relay.relayingCount;
        if (n == 0) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Card(
            child: ListTile(
              leading: Icon(
                Icons.device_hub_rounded,
                color: theme.colorScheme.primary,
              ),
              title: Text(
                'Helping $n ${n == 1 ? 'connection' : 'connections'} '
                'between nearby phones',
              ),
              subtitle: const Text('Encrypted: this phone cannot read it'),
              trailing: TextButton(
                onPressed: () => container.setRelayEnabled(false),
                child: const Text('Stop'),
              ),
            ),
          ),
        );
      },
    );
  }

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

  // ----------------------------------------------------------------- helpers

  Future<void> _startSearch(AppContainer container) async {
    setState(() => _isTogglingDiscovery = true);
    try {
      final raw = container.capabilityCoordinator.rawCapabilities;
      // Explain, then ask; if Android will not ask any more, the sheet
      // offers the settings page. Either way Wi-Fi discovery starts below.
      if (raw.isNearbyPermissionNotRequested ||
          (raw.isNearbyPermissionMissing && !raw.canUseLan)) {
        await ensureFeature(context, container, VayuFeature.findPhones);
      }
      await container.startDiscoveryAndAdvertising();
      container.discoverFor(AppContainer.discoveryWindow);
    } catch (error) {
      if (mounted) {
        showVayuNotice(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
          tone: VayuNoticeTone.problem,
        );
      }
    } finally {
      if (mounted) setState(() => _isTogglingDiscovery = false);
    }
  }
}

/// App name and whether this phone can be found right now.
class _HomeTitle extends StatelessWidget {
  final AppContainer container;

  const _HomeTitle({required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            gradient: palette.heroGradient,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(Icons.air_rounded, color: palette.heroGlow, size: 22),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppConstants.appName,
                style: theme.textTheme.titleLarge?.copyWith(
                  letterSpacing: -0.4,
                  height: 1.1,
                ),
              ),
              _Availability(container: container),
            ],
          ),
        ),
      ],
    );
  }
}

/// One line of truth about reachability: offline, findable, or paused.
class _Availability extends StatelessWidget {
  final AppContainer container;

  const _Availability({required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return StreamBuilder<EvaluatedCapabilityState>(
      stream: container.capabilityCoordinator.stateStream,
      initialData: container.capabilityCoordinator.state,
      builder: (context, capSnapshot) {
        final caps = capSnapshot.data ?? container.capabilityCoordinator.state;
        return StreamBuilder<DiscoveryStatus>(
          stream: container.discoveryStatusStream,
          initialData: container.discoveryStatus,
          builder: (context, statusSnapshot) {
            final active =
                (statusSnapshot.data ?? DiscoveryStatus.idle).isActive;
            final saver =
                container.orchestrator.currentState.isBatterySaverActive;
            final (String label, Color color) = !caps.hasAnyReady
                ? ('Offline · turn on Wi-Fi or Bluetooth', palette.warning)
                : active
                ? (
                    saver ? 'Visible nearby · Battery Saver' : 'Visible nearby',
                    palette.success,
                  )
                : ('Ready · search paused', theme.colorScheme.outline);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

enum _TileStyle { primary, accent, plain }

/// One of the four Home actions. Send is the ink tile, Receive the sage
/// tile; contacts and apps are quiet surfaces.
class _ActionTile extends StatelessWidget {
  final _TileStyle style;
  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  final bool busy;
  final VoidCallback? onTap;

  const _ActionTile({
    required this.style,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.badge,
    this.busy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final big = style != _TileStyle.plain;
    final (
      Color bg,
      Color fg,
      Color muted,
      Gradient? gradient,
    ) = switch (style) {
      _TileStyle.primary => (
        Colors.transparent,
        palette.onHero,
        palette.onHeroMuted,
        palette.heroGradient,
      ),
      _TileStyle.accent => (
        palette.accentContainer,
        theme.colorScheme.onSecondaryContainer,
        theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.75),
        null,
      ),
      _TileStyle.plain => (
        theme.colorScheme.surfaceContainerLowest,
        theme.colorScheme.onSurface,
        theme.colorScheme.onSurfaceVariant,
        null,
      ),
    };
    final radius = BorderRadius.circular(big ? 26 : 22);
    return Semantics(
      button: true,
      label: '$title, $subtitle',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            color: gradient == null ? bg : null,
            gradient: gradient,
            borderRadius: radius,
            border: style == _TileStyle.plain
                ? Border.all(color: theme.colorScheme.outlineVariant)
                : null,
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: big ? 132 : 96),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Wraps at large text sizes: the badge moves under the
                    // icon instead of overflowing.
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        busy
                            ? SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: fg,
                                ),
                              )
                            : Icon(icon, color: fg, size: big ? 28 : 24),
                        if (badge != null)
                          StatusPill(
                            label: badge!,
                            foreground: palette.warning,
                            background: palette.warningContainer,
                          ),
                      ],
                    ),
                    SizedBox(height: big ? 22 : 12),
                    Text(
                      title,
                      style:
                          (big
                                  ? theme.textTheme.titleLarge
                                  : theme.textTheme.titleSmall)
                              ?.copyWith(color: fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
