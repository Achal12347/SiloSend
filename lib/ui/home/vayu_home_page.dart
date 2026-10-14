import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
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
import 'package:vayu/platform/nfc_card_inbox.dart';
import 'package:vayu/platform/share_intent_service.dart';
import 'package:vayu/ui/settings/settings_page.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/incoming_batch_dialog.dart';
import 'package:vayu/ui/transfer/incoming_transfer_dialog.dart';
import 'package:vayu/ui/transfer/peer_selection_sheet.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/transfer/transfer_progress_card.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:flutter/services.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/ui/card/my_card_page.dart';
import 'package:vayu/ui/widgets/peer_picker_sheet.dart';
import 'package:vayu/ui/widgets/route_observer.dart';

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
    with SingleTickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  late AnimationController _pulseController;

  bool _isTogglingDiscovery = false;
  bool _isPickingHeroFile = false;
  final Set<String> _connectingPeerIds = {};
  StreamSubscription<IncomingTransferRequest>? _incomingRequestsSub;
  StreamSubscription<IncomingBatchRequest>? _incomingBatchesSub;
  ShareIntentService? _shareIntents;
  StreamSubscription<List<SelectedDocument>>? _sharedSub;

  // Cards received by tap while home is the visible screen.
  StreamSubscription<Uint8List>? _cardInboxSub;
  StreamSubscription<VayuCard?>? _myCardSub;
  bool _routeVisible = true;
  bool _appVisible = true;
  bool _subscribedToRoutes = false;
  Timer? _shareTimer;
  // Cards that arrived while another screen covered home; shown on return.
  final List<Uint8List> _waitingCards = [];

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

    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoStartDiscoveryIfReady();
      if (Platform.isAndroid && !isTesting) {
        _listenForSharedFiles();
        _listenForTappedCards();
        _scheduleCardSharing();
      }
    });
  }

  // ------------------------------------------------------------ tap to share
  //
  // While home is on screen this phone shares the user's card over NFC, both
  // to Vayu and as a standard tag, so a phone tapped against it receives the
  // card even when Vayu is closed there. Cards from other phones arrive
  // through Android's tag reader (NfcCardInbox). Sharing stops whenever
  // another screen covers home or the app leaves the screen.

  bool get _nfcEnabledHere =>
      Platform.isAndroid &&
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      !WidgetsBinding.instance.runtimeType.toString().contains('Test');

  /// Starts sharing shortly after home becomes visible: the screen that just
  /// closed stops its own sharing as it is torn down, which happens after
  /// home is already visible again.
  void _scheduleCardSharing() {
    _shareTimer?.cancel();
    if (!_nfcEnabledHere) return;
    _shareTimer = Timer(const Duration(milliseconds: 600), _shareCardNow);
  }

  void _shareCardNow() {
    if (!mounted || !_routeVisible || !_appVisible) return;
    final container = AppScope.of(context);
    final card = container.myCard;
    if (card == null) return;
    container.nfcPairingService.shareCard(card.toVcard()).ignore();
  }

  void _stopCardSharing() {
    _shareTimer?.cancel();
    if (!_nfcEnabledHere || !mounted) return;
    AppScope.of(context).nfcPairingService.stopSharing().ignore();
  }

  Future<void> _listenForTappedCards() async {
    const inbox = NfcCardInbox();
    _cardInboxSub = inbox.cards.listen(_onCardTapped);
    final pending = await inbox.takePending();
    if (pending != null) _onCardTapped(pending);
  }

  @override
  void didPushNext() {
    // Another screen (pairing, receive, profile, a sheet) now owns NFC.
    _routeVisible = false;
    _stopCardSharing();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _scheduleCardSharing();
    if (_waitingCards.isNotEmpty) {
      final next = _waitingCards.removeAt(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onCardTapped(next));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never share the card while Vayu is not on screen.
    _appVisible = state == AppLifecycleState.resumed;
    if (_appVisible) {
      _scheduleCardSharing();
    } else {
      _stopCardSharing();
    }
  }

  Future<void> _onCardTapped(Uint8List bytes) async {
    if (!mounted) return;
    final card = ContactCard.tryParse(bytes);
    if (card == null) return;
    if (!_routeVisible) {
      _waitingCards.add(bytes);
      return;
    }
    HapticFeedback.mediumImpact();
    final container = AppScope.of(context);
    await showReceivedCardSheet(
      context,
      container: container,
      card: card,
      onSave: () => _saveTappedCard(container, card),
    );
  }

  /// Keeps the card in app-private storage, records it in History, and hands
  /// it to the phone's contacts app, where the user confirms the save.
  Future<void> _saveTappedCard(AppContainer container, ContactCard card) async {
    try {
      final dir =
          await const ContactPicker().privateDirectory() ??
          await container.storageService.getDownloadsDirectory();
      final path = await container.storageService.resolveUniqueDestinationPath(
        dir,
        ContactCard.fileNameFor(card.displayName),
      );
      await File(path).writeAsBytes(card.vcard, flush: true);
      await container.fileSharingCoordinator.history?.add(
        TransferHistoryRecord(
          transferId: 'tap-${DateTime.now().microsecondsSinceEpoch}',
          outbound: false,
          peerDeviceId: '',
          peerName: card.displayName,
          fileName: ContactCard.fileNameFor(card.displayName),
          sizeBytes: card.vcard.length,
          mimeType: 'text/vcard',
          isContact: true,
          outcome: TransferOutcome.completed,
          finishedAt: DateTime.now(),
          savedPath: path,
        ),
      );
      await container.platformService.openFile(path, mimeType: 'text/x-vcard');
    } catch (e) {
      if (mounted) _showError(friendlyError(e));
    }
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
      // Nearby access is asked in onboarding, by the setup banner, or when
      // the user taps Send; never unprompted here.
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
    final route = ModalRoute.of(context);
    if (!_subscribedToRoutes && route != null) {
      vayuRouteObserver.subscribe(this, route);
      _subscribedToRoutes = true;
    }
    if (container.isInitialized) {
      // Re-share when the card is created or edited.
      _myCardSub ??= container.myCardStream.listen(
        (_) => _scheduleCardSharing(),
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
    vayuRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _cardInboxSub?.cancel();
    _myCardSub?.cancel();
    _stopCardSharing();
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
            icon: const Icon(Icons.badge_outlined),
            tooltip: 'My card',
            onPressed: () => MyCardPage.open(context, container),
          ),
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
        _showError('Couldn\'t open your files. Please try again.');
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
      showVayuNotice(
        null,
        messenger: messenger,
        'Connected to ${peer.displayName}',
        tone: VayuNoticeTone.success,
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
        _showError(friendlyError(e, peerName: peer.displayName));
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
      if (mounted) _showError(friendlyError(e));
    }
  }

  /// Hero flow for contacts: pick the contact first, then the device.
  Future<void> _shareContactFromHero(AppContainer container) async {
    final contact = await _pickContact();
    if (contact == null || !mounted) return;
    final peer = await pickNearbyPeer(
      context,
      container: container,
      title: 'Send ${contact.name} to',
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
        if (mounted) _showError(friendlyError(e));
      }
    }
  }

  void _showError(String message) {
    showVayuNotice(context, message, tone: VayuNoticeTone.problem);
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

/// Battery Saver notice on the hero, shown only while it is active. Setup
/// problems are explained by the setup banner instead.
class _ReadinessLine extends StatelessWidget {
  final AppContainer container;
  final Color color;

  const _ReadinessLine({required this.container, required this.color});

  @override
  Widget build(BuildContext context) {
    final palette = VayuPalette.of(context);
    return StreamBuilder<AppOrchestratorState>(
      stream: container.orchestratorStateStream,
      initialData: container.orchestrator.currentState,
      builder: (context, orchestrator) {
        final saver = orchestrator.data?.isBatterySaverActive ?? false;
        if (!saver) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: StatusPill(
            label: 'Battery Saver',
            icon: Icons.battery_saver_rounded,
            foreground: color,
            background: palette.onHero.withValues(alpha: 0.08),
          ),
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
