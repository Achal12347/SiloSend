import 'package:flutter/material.dart';

import 'package:silosend_datasharing_app/core/constants/app_constants.dart';
import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/state/app_container.dart';
import 'package:silosend_datasharing_app/core/state/app_scope.dart';
import 'package:silosend_datasharing_app/domain/identity/local_device_identity.dart';
import 'package:silosend_datasharing_app/ui/connection/active_connections_card.dart';
import 'package:silosend_datasharing_app/ui/pairing/pairing_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SiloSendApp());
}

/// Root widget for the SiloSend application.
class SiloSendApp extends StatefulWidget {
  final AppContainer? container;

  const SiloSendApp({super.key, this.container});

  @override
  State<SiloSendApp> createState() => _SiloSendAppState();
}

class _SiloSendAppState extends State<SiloSendApp> {
  late final AppContainer _container;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _container = widget.container ?? AppContainer.standard();
    _initFuture = _container.isInitialized
        ? Future.value()
        : _container.initialize();
  }

  @override
  void dispose() {
    if (widget.container == null) {
      _container.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      container: _container,
      child: MaterialApp(
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1E88E5), // SiloSend blue
            brightness: Brightness.light,
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1E88E5),
            brightness: Brightness.dark,
          ),
        ),
        themeMode: ThemeMode.system,
        home: FutureBuilder<void>(
          future: _initFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Initializing device identity...'),
                    ],
                  ),
                ),
              );
            }
            if (snapshot.hasError) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 64,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Initialization Error',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${snapshot.error}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return const SiloSendHomePage();
          },
        ),
      ),
    );
  }
}

/// Initial home page for SiloSend displaying truthful, real application state.
class SiloSendHomePage extends StatefulWidget {
  const SiloSendHomePage({super.key});

  @override
  State<SiloSendHomePage> createState() => _SiloSendHomePageState();
}

class _SiloSendHomePageState extends State<SiloSendHomePage> {
  bool _isBusy = false;
  final Set<String> _connectingPeerIds = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final container = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_2_rounded),
            tooltip: 'Out-of-Band Pairing',
            onPressed: () => PairingDialog.show(context, container),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.share_rounded,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 8),
              Text(
                AppConstants.appName,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Offline Device-to-Device Sharing',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),

              // Local Device Identity Card
              StreamBuilder<LocalDeviceIdentity>(
                stream: container.identityStream,
                initialData: container.identity,
                builder: (context, snapshot) {
                  final identity = snapshot.data;
                  final displayName = identity?.displayName ?? 'Loading...';
                  final fullHex = identity?.idHex ?? '';
                  final truncatedId = fullHex.length >= 12
                      ? '${fullHex.substring(0, 8)}...${fullHex.substring(fullHex.length - 4)}'
                      : fullHex;

                  return Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.perm_identity_rounded,
                                size: 20,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Local Device Identity',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          _buildInfoRow(
                            theme: theme,
                            label: 'Display Name',
                            value: displayName,
                            bold: true,
                          ),
                          const SizedBox(height: 8),
                          _buildInfoRow(
                            theme: theme,
                            label: 'Device ID',
                            value: truncatedId.isNotEmpty
                                ? truncatedId
                                : 'Not assigned',
                            tooltip: identity?.uuid,
                          ),
                          const SizedBox(height: 8),
                          _buildInfoRow(
                            theme: theme,
                            label: 'Platform',
                            value: container.platformService.platformName,
                          ),
                          const SizedBox(height: 8),
                          _buildInfoRow(
                            theme: theme,
                            label: 'Protocol Version',
                            value:
                                'v${identity?.protocolVersion ?? AppConstants.protocolVersion}',
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),

              // Device Discovery Section (Phase 4)
              StreamBuilder<DiscoveryStatus>(
                stream: container.discoveryStatusStream,
                initialData: container.discoveryStatus,
                builder: (context, statusSnapshot) {
                  final status = statusSnapshot.data ?? DiscoveryStatus.idle;
                  final isScanning = status.isActive;

                  return Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.radar_rounded,
                                    size: 20,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Nearby Device Discovery',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              if (isScanning)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                            ],
                          ),
                          const Divider(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Status: ${status.name.toUpperCase()}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: isScanning
                                      ? Colors.green.shade700
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _isBusy
                                    ? null
                                    : () async {
                                        setState(() => _isBusy = true);
                                        try {
                                          if (isScanning) {
                                            await container
                                                .stopDiscoveryAndAdvertising();
                                          } else {
                                            await container
                                                .startDiscoveryAndAdvertising();
                                          }
                                        } finally {
                                          if (mounted) {
                                            setState(() => _isBusy = false);
                                          }
                                        }
                                      },
                                icon: Icon(
                                  isScanning
                                      ? Icons.stop_rounded
                                      : Icons.search_rounded,
                                  size: 18,
                                ),
                                label: Text(
                                  isScanning ? 'Stop' : 'Scan Nearby',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Discovered Peers Stream
                          StreamBuilder<List<DiscoveredPeer>>(
                            stream: container.discoveredPeersStream,
                            initialData: container.discoveredPeers,
                            builder: (context, peerSnapshot) {
                              final peers = peerSnapshot.data ?? [];

                              if (!isScanning && peers.isEmpty) {
                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12.0,
                                    ),
                                    child: Text(
                                      'Discovery inactive. Press "Scan Nearby" to search.',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                );
                              }

                              if (peers.isEmpty) {
                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16.0,
                                    ),
                                    child: Text(
                                      'No nearby devices discovered yet.\n(Real device beacons only — no fake peers)',
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                );
                              }

                              return Column(
                                children: peers
                                    .map(
                                      (peer) => _buildPeerCard(
                                        theme,
                                        container,
                                        peer,
                                      ),
                                    )
                                    .toList(),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),

              // Active Connections Section (Phase 5)
              ActiveConnectionsCard(container: container),
              const SizedBox(height: 16),

              // Application Lifecycle Card
              StreamBuilder<AppLifecycleState>(
                stream: container.lifecycleStream,
                initialData: container.lifecycleState,
                builder: (context, snapshot) {
                  final state = snapshot.data ?? AppLifecycleState.resumed;
                  final isForeground = state == AppLifecycleState.resumed;

                  return Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.sync_rounded,
                                size: 20,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Application Lifecycle',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          _buildInfoRow(
                            theme: theme,
                            label: 'Lifecycle State',
                            value: isForeground
                                ? 'Foreground (Active)'
                                : state.name,
                            bold: true,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),

              // Truthful Hardware Capabilities Card
              Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.settings_input_antenna_rounded,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Hardware Capabilities',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      _buildInfoRow(
                        theme: theme,
                        label: 'Bluetooth Low Energy',
                        value: container.capabilities.ble.displayLabel,
                      ),
                      const SizedBox(height: 8),
                      _buildInfoRow(
                        theme: theme,
                        label: 'Wi-Fi Direct',
                        value: container.capabilities.wifiDirect.displayLabel,
                      ),
                      const SizedBox(height: 8),
                      _buildInfoRow(
                        theme: theme,
                        label: 'Camera',
                        value: container.capabilities.camera.displayLabel,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Honest State Indicator
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Truthful Discovery & Connection Foundation Active',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPeerCard(
    ThemeData theme,
    AppContainer container,
    DiscoveredPeer peer,
  ) {
    final truncatedId = peer.deviceId.length >= 12
        ? '${peer.deviceId.substring(0, 8)}...${peer.deviceId.substring(peer.deviceId.length - 4)}'
        : peer.deviceId;

    final isConnecting = _connectingPeerIds.contains(peer.deviceId);
    final isConnected = container.connectionManager.hasSessionWithDevice(
      peer.deviceId,
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                peer.displayName,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Unverified Claim',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber.shade900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ID: $truncatedId',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Wrap(
                spacing: 4,
                children: peer.availableTransports.map((t) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      t.name.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (isConnected)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.green.shade300),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: Colors.green.shade700,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Connected',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade800,
                        ),
                      ),
                    ],
                  ),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: isConnecting
                      ? null
                      : () async {
                          setState(() => _connectingPeerIds.add(peer.deviceId));
                          try {
                            await container.connectToPeer(peer);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Connected to ${peer.displayName}!',
                                  ),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Failed to connect to ${peer.displayName}: $e',
                                  ),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(
                                () => _connectingPeerIds.remove(peer.deviceId),
                              );
                            }
                          }
                        },
                  icon: isConnecting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link_rounded, size: 16),
                  label: Text(isConnecting ? 'Connecting...' : 'Connect'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required ThemeData theme,
    required String label,
    required String value,
    bool bold = false,
    String? tooltip,
  }) {
    Widget valueWidget = Text(
      value,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      ),
    );

    if (tooltip != null) {
      valueWidget = Tooltip(message: tooltip, child: valueWidget);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        valueWidget,
      ],
    );
  }
}
