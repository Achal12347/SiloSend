import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:vayu/core/capabilities/capability_coordinator.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/ui/connection/active_connections_card.dart';
import 'package:vayu/ui/home/capability_setup_banner.dart';
import 'package:vayu/ui/home/discovered_peer_card.dart';
import 'package:vayu/core/state/app_orchestrator.dart';
import 'package:vayu/ui/home/local_device_card.dart';
import 'package:vayu/ui/pairing/pairing_dialog.dart';
import 'package:vayu/ui/settings/settings_page.dart';
import 'package:vayu/ui/transfer/incoming_transfer_dialog.dart';
import 'package:vayu/ui/transfer/peer_selection_sheet.dart';
import 'package:vayu/ui/transfer/transfer_progress_card.dart';

/// Primary production Home screen for Vayu (Phase 14).
///
/// Designed with product-first flow, dynamic capability UX, and cohesive state orchestration:
/// 1. Header: Vayu branding + live transport readiness indicator + pairing & refresh actions
/// 2. Hero Section: "Send File" primary CTA leading to native SAF picker & peer selection
/// 3. Dynamic Capability UX: Contextual permission & radio setup with 1-tap recovery
/// 4. Nearby Devices: Live discovery radar with real transports, real peers, and actionable states
/// 5. Active Transfers: Real-time progress, speed, ETA, and direct file open
/// 6. Active Connections: Authenticated P2P sessions with Short Authentication String (SAS)
/// 7. Your Device: Compact local identity, editable name, and cryptographic fingerprint
/// 8. Footer: Privacy and offline encryption reassurance
class VayuHomePage extends StatefulWidget {
  const VayuHomePage({super.key});

  @override
  State<VayuHomePage> createState() => _VayuHomePageState();
}

class _VayuHomePageState extends State<VayuHomePage>
    with SingleTickerProviderStateMixin {
  late AnimationController _radarAnimController;
  late Animation<double> _pulseAnimation;

  bool _isTogglingDiscovery = false;
  bool _isPickingHeroFile = false;
  final Set<String> _connectingPeerIds = {};
  StreamSubscription<IncomingTransferRequest>? _incomingRequestsSub;

  @override
  void initState() {
    super.initState();
    _radarAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    final isTesting = Platform.environment.containsKey('FLUTTER_TEST') ||
        WidgetsBinding.instance.runtimeType.toString().contains('Test');
    if (!isTesting) {
      _radarAnimController.repeat(reverse: true);
    } else {
      _radarAnimController.value = 1.0;
    }

    _pulseAnimation = Tween<double>(begin: 0.88, end: 1.12).animate(
      CurvedAnimation(parent: _radarAnimController, curve: Curves.easeInOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoStartDiscoveryIfReady();
    });
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
  }

  @override
  void dispose() {
    _radarAnimController.dispose();
    _incomingRequestsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final container = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.swap_horizontal_circle_rounded,
                size: 20,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              AppConstants.appName,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
        centerTitle: false,
        actions: [
          // Live Transport Status Chip
          _buildTransportStatusChip(theme, container),
          _buildBatterySaverStatusChip(theme, container),
          IconButton(
            icon: const Icon(Icons.qr_code_2_rounded),
            tooltip: 'Pair Device (QR / NFC)',
            onPressed: () => PairingDialog.show(context, container),
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
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Connectivity',
            onPressed: () async {
              await container.capabilityCoordinator.refresh();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Capabilities refreshed'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Hero Send File Section (Top Primary Action)
              _buildHeroSendSection(context, theme, container),
              const SizedBox(height: 14),

              // 2. Contextual Capability & Permission Banner
              CapabilitySetupBanner(container: container),

              // 3. Nearby Devices Discovery Section
              _buildNearbyDevicesSection(theme, container),
              const SizedBox(height: 14),

              // 4. Active File Transfers Section (Phase 7 & 9)
              TransferProgressCard(container: container),
              const SizedBox(height: 14),

              // 5. Active Connections Section (Phase 5 & 6)
              ActiveConnectionsCard(container: container),
              const SizedBox(height: 14),

              // 6. Local Device Identity Card
              LocalDeviceCard(container: container),
              const SizedBox(height: 20),

              // 7. Trust & Encryption Assurance Footer
              _buildFooterAssurance(theme),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact live connectivity chip in the AppBar.
  Widget _buildTransportStatusChip(ThemeData theme, AppContainer container) {
    return StreamBuilder<EvaluatedCapabilityState>(
      stream: container.capabilityCoordinator.stateStream,
      initialData: container.capabilityCoordinator.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? container.capabilityCoordinator.state;
        final Color dotColor;
        final String label;

        switch (state.operationalStatus) {
          case CapabilityOperationalStatus.readyBoth:
            dotColor = Colors.green.shade600;
            label = 'Wi-Fi + BLE';
            break;
          case CapabilityOperationalStatus.readyLanOnly:
            dotColor = Colors.teal.shade600;
            label = 'Wi-Fi';
            break;
          case CapabilityOperationalStatus.readyBleOnly:
            dotColor = Colors.blue.shade600;
            label = 'BLE';
            break;
          case CapabilityOperationalStatus.checking:
            dotColor = Colors.amber.shade700;
            label = 'Checking...';
            break;
          case CapabilityOperationalStatus.actionRequired:
            dotColor = Colors.orange.shade700;
            label = 'Setup';
            break;
        }

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: dotColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: dotColor.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: dotColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Compact Battery Saver status indicator in AppBar.
  Widget _buildBatterySaverStatusChip(
    ThemeData theme,
    AppContainer container,
  ) {
    return StreamBuilder<AppOrchestratorState>(
      stream: container.orchestratorStateStream,
      initialData: container.orchestrator.currentState,
      builder: (context, snapshot) {
        final isSaver = snapshot.data?.isBatterySaverActive ?? false;
        if (!isSaver) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.orange.shade100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.shade300),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.battery_saver_rounded,
                size: 13,
                color: Colors.orange.shade900,
              ),
              const SizedBox(width: 3),
              Text(
                'Saver',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange.shade900,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Hero action card putting the primary product function ("Send File") front and center.
  Widget _buildHeroSendSection(
    BuildContext context,
    ThemeData theme,
    AppContainer container,
  ) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primaryContainer.withValues(alpha: 0.85),
            theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.25),
        ),
      ),
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Send Files Nearby',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Fast, direct, encrypted. No internet required.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary,
                ),
                child: Icon(
                  Icons.send_rounded,
                  color: theme.colorScheme.onPrimary,
                  size: 24,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: _isPickingHeroFile
                  ? null
                  : () => _onHeroSendFilePressed(container),
              icon: _isPickingHeroFile
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.file_upload_outlined, size: 20),
              label: Text(
                _isPickingHeroFile ? 'Selecting Document...' : 'Send File',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Nearby devices card with live status, transport indicators, and discovered peers.
  Widget _buildNearbyDevicesSection(ThemeData theme, AppContainer container) {
    return StreamBuilder<DiscoveryStatus>(
      stream: container.discoveryStatusStream,
      initialData: container.discoveryStatus,
      builder: (context, statusSnapshot) {
        final status = statusSnapshot.data ?? DiscoveryStatus.idle;
        final isScanning = status.isActive;

        return Card(
          elevation: 0,
          color: theme.colorScheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        AnimatedBuilder(
                          animation: _pulseAnimation,
                          builder: (context, child) {
                            return Transform.scale(
                              scale: isScanning ? _pulseAnimation.value : 1.0,
                              child: child,
                            );
                          },
                          child: Icon(
                            Icons.radar_rounded,
                            size: 22,
                            color: isScanning
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Nearby Devices',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _isTogglingDiscovery
                          ? null
                          : () => _toggleDiscovery(container, isScanning),
                      icon: isScanning
                          ? const Icon(Icons.stop_rounded, size: 16)
                          : const Icon(Icons.search_rounded, size: 16),
                      label: Text(isScanning ? 'Stop' : 'Scan Nearby'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                      ),
                    ),
                  ],
                ),

                // Active Transports Row
                if (isScanning) ...[
                  const SizedBox(height: 10),
                  _buildActiveTransportsRow(theme, container),
                ],

                const Divider(height: 20),

                // Discovered Peers Stream & Operational States
                StreamBuilder<List<DiscoveredPeer>>(
                  stream: container.discoveredPeersStream,
                  initialData: container.discoveredPeers,
                  builder: (context, peerSnapshot) {
                    final peers = peerSnapshot.data ?? [];

                    return StreamBuilder<DiscoveryOperationalState>(
                      stream:
                          container.discoveryCoordinator.operationalStateStream,
                      initialData:
                          container.discoveryCoordinator.operationalState,
                      builder: (context, opStateSnapshot) {
                        final opState =
                            opStateSnapshot.data ??
                            container.discoveryCoordinator.operationalState;

                        if (peers.isNotEmpty) {
                          return Column(
                            children: peers.map((peer) {
                              return DiscoveredPeerCard(
                                container: container,
                                peer: peer,
                                isConnecting: _connectingPeerIds.contains(
                                  peer.deviceId,
                                ),
                                onConnectPressed: () =>
                                    _connectToPeer(container, peer),
                                onSendFilePressed: () =>
                                    _sendFileToPeerDirect(container, peer),
                              );
                            }).toList(),
                          );
                        }

                        // Empty / Scanning States
                        return _buildOperationalEmptyState(
                          theme,
                          container,
                          isScanning: isScanning,
                          opState: opState,
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Displays active transport badges (Wi-Fi, Bluetooth) during scanning.
  Widget _buildActiveTransportsRow(ThemeData theme, AppContainer container) {
    final active = container.discoveryCoordinator.activeTransports;

    return Row(
      children: [
        Text(
          'Scanning over: ',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 11,
          ),
        ),
        if (active.contains(TransportType.lan))
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.teal.shade200),
            ),
            child: Text(
              'Wi-Fi Local',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.teal.shade800,
              ),
            ),
          ),
        if (active.contains(TransportType.ble))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Text(
              'Bluetooth LE',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.blue.shade800,
              ),
            ),
          ),
        if (active.isEmpty)
          Text(
            'Initializing radios...',
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  /// Evaluates truthful DiscoveryOperationalState when no peers are visible.
  Widget _buildOperationalEmptyState(
    ThemeData theme,
    AppContainer container, {
    required bool isScanning,
    required DiscoveryOperationalState opState,
  }) {
    if (!isScanning) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20.0),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.sensors_off_rounded,
                size: 36,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.6,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Nearby discovery is paused',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Tap "Search" to find nearby Vayu devices.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _toggleDiscovery(container, false),
                icon: const Icon(Icons.search_rounded, size: 16),
                label: const Text('Start Discovery'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (opState == DiscoveryOperationalState.noDevices) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18.0),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.devices_other_rounded,
                size: 34,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'No Vayu devices found nearby',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Make sure Vayu is open on both devices and Wi-Fi or Bluetooth is enabled.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await _toggleDiscovery(container, true);
                  await _toggleDiscovery(container, false);
                },
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Search Again'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Default scanning/searching state
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22.0),
      child: Center(
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _pulseAnimation.value,
                  child: child,
                );
              },
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.6,
                  ),
                ),
                child: Icon(
                  Icons.radar_rounded,
                  size: 24,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Searching for nearby devices...',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Looking for active Vayu beacons on local Wi-Fi and Bluetooth.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Footer assurance indicating truthful offline encryption primitives.
  Widget _buildFooterAssurance(ThemeData theme) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.shield_outlined,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            'End-to-End Encrypted (AES-256-GCM) • Offline Direct',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  /// Primary Hero CTA flow: native SAF document picker -> nearby peer selection sheet.
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('File selection error: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingHeroFile = false);
      }
    }
  }

  /// Starts or stops discovery scanning and advertising truthfully.
  Future<void> _toggleDiscovery(
    AppContainer container,
    bool isCurrentlyScanning,
  ) async {
    setState(() => _isTogglingDiscovery = true);
    final messenger = ScaffoldMessenger.of(context);
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
        final message = error.toString().replaceFirst('Bad state: ', '');
        messenger.showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTogglingDiscovery = false);
      }
    }
  }

  /// Connects point-to-point to a discovered peer.
  Future<void> _connectToPeer(
    AppContainer container,
    DiscoveredPeer peer,
  ) async {
    setState(() => _connectingPeerIds.add(peer.deviceId));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await container.connectToPeer(peer);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Connected to ${peer.displayName}'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Unable to connect to ${peer.displayName}. Check proximity and retry.',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _connectingPeerIds.remove(peer.deviceId));
      }
    }
  }

  /// Direct Send File flow from a specific peer card.
  Future<void> _sendFileToPeerDirect(
    AppContainer container,
    DiscoveredPeer peer,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final task = await container.fileSharingCoordinator.sendFileToPeer(peer);
      if (task != null && mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Sending "${task.metadata.fileName}" to ${peer.displayName}...',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('File send error: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }
}
