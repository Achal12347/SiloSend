import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:silosend_datasharing_app/core/battery/battery_snapshot.dart';
import 'package:silosend_datasharing_app/core/capabilities/capability_coordinator.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/state/app_container.dart';
import 'package:silosend_datasharing_app/core/state/app_orchestrator.dart';
import 'package:silosend_datasharing_app/domain/identity/system_capabilities.dart';

/// Diagnostics & Live Telemetry Screen (UI11 & Section 32).
///
/// Exposes truthful real-time hardware, network, cryptographic, and battery telemetry
/// for troubleshooting and multi-device validation.
///
/// Adheres strictly to the SiloSend No Mock Data rule:
/// - Any unprobed or unsupported metrics are reported truthfully as "Unknown" or "Unavailable".
/// - Private keys or sensitive cryptographic seeds are NEVER displayed.
class DiagnosticsPage extends StatefulWidget {
  final AppContainer container;

  const DiagnosticsPage({super.key, required this.container});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  BatterySnapshot _batterySnapshot = BatterySnapshot.unknown();

  @override
  void initState() {
    super.initState();
    _refreshBattery();
  }

  Future<void> _refreshBattery() async {
    try {
      final snap = await widget.container.batteryProvider.getBatterySnapshot();
      if (mounted) {
        setState(() {
          _batterySnapshot = snap;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final container = widget.container;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics & Telemetry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Telemetry',
            onPressed: () async {
              await container.capabilityCoordinator.refresh();
              await _refreshBattery();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Diagnostics refreshed'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            tooltip: 'Copy Diagnostics',
            onPressed: () => _copyDiagnosticsToClipboard(context),
          ),
        ],
      ),
      body: StreamBuilder<EvaluatedCapabilityState>(
        stream: container.capabilityCoordinator.stateStream,
        initialData: container.capabilityCoordinator.state,
        builder: (context, capSnapshot) {
          final caps =
              capSnapshot.data?.capabilities ??
              container.capabilityCoordinator.rawCapabilities;

          return StreamBuilder<AppOrchestratorState>(
            stream: container.orchestratorStateStream,
            initialData: container.orchestrator.currentState,
            builder: (context, orchSnapshot) {
              final orchState =
                  orchSnapshot.data ?? container.orchestrator.currentState;

              return ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 12.0,
                ),
                children: [
                  _buildSectionHeader(theme, 'Android & System Platform'),
                  _buildCard(theme, [
                    _buildRow(
                      'Operating System',
                      Platform.operatingSystem.toUpperCase(),
                      isOk: Platform.isAndroid,
                    ),
                    _buildRow(
                      'OS Version',
                      Platform.operatingSystemVersion,
                    ),
                    _buildRow(
                      'Platform Status',
                      Platform.isAndroid ? 'Supported' : 'Non-Android (Limited)',
                      isOk: Platform.isAndroid,
                    ),
                  ]),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Bluetooth Low Energy (BLE)'),
                  _buildCard(theme, [
                    _buildRow(
                      'Hardware Support',
                      caps.bluetoothState != RadioState.unsupported
                          ? 'Available'
                          : 'Unsupported',
                      isOk: caps.bluetoothState != RadioState.unsupported,
                    ),
                    _buildRow(
                      'Radio State',
                      caps.bluetoothState.name.toUpperCase(),
                      isOk: caps.bluetoothState == RadioState.enabled,
                    ),
                    _buildRow(
                      'BLE Scanning',
                      container.discoveryCoordinator.activeTransports.contains(
                            TransportType.ble,
                          )
                          ? 'Active'
                          : 'Idle',
                      isOk: container.discoveryCoordinator.activeTransports
                          .contains(TransportType.ble),
                    ),
                    _buildRow(
                      'BLE Advertising',
                      container.discoveryCoordinator.status.isActive
                          ? 'Active'
                          : 'Inactive',
                      isOk: container.discoveryCoordinator.status.isActive,
                    ),
                  ]),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Local Area Network (LAN)'),
                  _buildCard(theme, [
                    _buildRow(
                      'Network State',
                      caps.lanState.name.toUpperCase(),
                      isOk: caps.lanState == NetworkState.lanAvailable,
                    ),
                    _buildRow(
                      'LAN Discovery (mDNS)',
                      container.discoveryCoordinator.activeTransports.contains(
                            TransportType.lan,
                          )
                          ? 'Active'
                          : 'Idle',
                      isOk: container.discoveryCoordinator.activeTransports
                          .contains(TransportType.lan),
                    ),
                    _buildRow(
                      'TCP Server Port',
                      container.lanServer?.boundPort != null
                          ? '${container.lanServer!.boundPort}'
                          : 'Not bound',
                      isOk: container.lanServer?.boundPort != null,
                    ),
                  ]),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Near Field Communication (NFC)'),
                  _buildCard(theme, [
                    _buildRow(
                      'NFC Hardware',
                      container.capabilities.nfc.displayLabel,
                      isOk: container.capabilities.supportsNfc,
                    ),
                  ]),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Permissions State'),
                  _buildCard(theme, [
                    _buildRow(
                      'Nearby Devices (BLE)',
                      caps.nearbyPermission.name.toUpperCase(),
                      isOk: caps.nearbyPermission == PermissionStatus.granted,
                    ),
                    _buildRow(
                      'Location (Legacy BLE)',
                      caps.locationRequiredForBle
                          ? (caps.locationEnabled ? 'ENABLED' : 'DISABLED')
                          : 'NOT REQUIRED',
                      isOk: !caps.locationRequiredForBle || caps.locationEnabled,
                    ),
                    _buildRow(
                      'Wi-Fi Radio',
                      caps.wifiEnabled ? 'ENABLED' : 'DISABLED',
                      isOk: caps.wifiEnabled,
                    ),
                  ]),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Security & Cryptographic Identity'),
                  _buildCard(theme, [
                    _buildRow(
                      'Local Device ID',
                      container.identity?.idHex ?? 'Unknown',
                    ),
                    _buildRow(
                      'Display Name',
                      container.identity?.displayName ?? 'Unknown',
                    ),
                    _buildRow(
                      'Public Key Fingerprint (Ed25519)',
                      container.localKeypair?.publicKeyHex != null
                          ? '${container.localKeypair!.publicKeyHex.substring(0, 16)}...'
                          : 'Uninitialized',
                      isOk: container.localKeypair != null,
                    ),
                    _buildRow(
                      'Active Secure Sessions',
                      '${container.activeSecureSessions.length}',
                    ),
                    _buildRow(
                      'Private Keys',
                      'Protected & Never Displayed',
                      isOk: true,
                    ),
                  ]),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Battery & Power Conservation'),
                  _buildCard(theme, [
                    _buildRow(
                      'Battery Level',
                      _batterySnapshot.batteryLevel != null
                          ? '${_batterySnapshot.batteryLevel}%'
                          : 'Unknown / Not Probed',
                    ),
                    _buildRow(
                      'Power Status',
                      _batterySnapshot.isCharging != null
                          ? (_batterySnapshot.isCharging!
                              ? 'Charging / Plugged in'
                              : 'Discharging')
                          : 'Unknown',
                    ),
                    _buildRow(
                      'Android Power Saver',
                      _batterySnapshot.isBatterySaverActive != null
                          ? (_batterySnapshot.isBatterySaverActive!
                              ? 'Active'
                              : 'Inactive')
                          : 'Unknown',
                    ),
                    _buildRow(
                      'SiloSend Battery Mode',
                      container.userSettings.batterySaverMode.displayName,
                    ),
                    _buildRow(
                      'Effective Discovery Throttling',
                      orchState.isBatterySaverActive
                          ? 'Active (Low Duty Cycle)'
                          : 'Standard (Low Latency)',
                    ),
                  ]),
                  const SizedBox(height: 16),

                  _buildSectionHeader(theme, 'Transfer Engine & State Machine'),
                  _buildCard(theme, [
                    _buildRow(
                      'Operational Phase',
                      orchState.phase.name.toUpperCase(),
                    ),
                    _buildRow(
                      'Discovered Peers In Range',
                      '${orchState.discoveredPeersCount}',
                    ),
                    _buildRow(
                      'Active Transfers',
                      '${container.activeTransfers.length}',
                    ),
                    _buildRow(
                      'Last Explicit Error',
                      orchState.explicitError.name,
                      isOk: orchState.explicitError == AppExplicitError.none,
                    ),
                  ]),
                  const SizedBox(height: 24),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4.0, bottom: 6.0),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildCard(ThemeData theme, List<Widget> children) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1)
                const Divider(height: 12, thickness: 0.5),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRow(String label, String value, {bool? isOk}) {
    Color? valColor;
    if (isOk == true) {
      valColor = Colors.green.shade700;
    } else if (isOk == false) {
      valColor = Colors.orange.shade800;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: valColor,
                fontFamily: value.length > 20 ? 'monospace' : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _copyDiagnosticsToClipboard(BuildContext context) {
    final container = widget.container;
    final orch = container.orchestrator.currentState;
    final caps = container.capabilityCoordinator.rawCapabilities;

    final buffer = StringBuffer();
    buffer.writeln('# SiloSend Diagnostics Report');
    buffer.writeln('- Timestamp: ${DateTime.now().toIso8601String()}');
    buffer.writeln('- OS: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})');
    buffer.writeln('- Device ID: ${container.identity?.idHex ?? "Unknown"}');
    buffer.writeln('- Display Name: ${container.identity?.displayName ?? "Unknown"}');
    buffer.writeln('- Public Key Fingerprint: ${container.localKeypair?.publicKeyHex.substring(0, 16) ?? "None"}...');
    buffer.writeln('- Bluetooth: ${caps.bluetoothState.name}');
    buffer.writeln('- LAN: ${caps.lanState.name} (Port: ${container.lanServer?.boundPort ?? 53531})');
    buffer.writeln('- NFC: ${container.capabilities.nfc.name}');
    buffer.writeln('- Permissions: nearby=${caps.nearbyPermission.name}, locationRequired=${caps.locationRequiredForBle}, locationEnabled=${caps.locationEnabled}');
    buffer.writeln('- Battery: level=${_batterySnapshot.batteryLevel}%, charging=${_batterySnapshot.isCharging}, saver=${_batterySnapshot.isBatterySaverActive}');
    buffer.writeln('- SiloSend Battery Mode: ${container.userSettings.batterySaverMode.displayName}');
    buffer.writeln('- Operational Phase: ${orch.phase.name}');
    buffer.writeln('- Explicit Error: ${orch.explicitError.name}');

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Diagnostics copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
