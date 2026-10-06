import 'package:flutter/material.dart';
import 'package:vayu/core/capabilities/capability_coordinator.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/ui/settings/permissions_rationale_dialog.dart';

/// Contextual capability and permission setup card.
///
/// Informs the user in clear, human language about missing permissions or radios
/// and provides direct, truthful recovery actions:
/// - [Allow Nearby Devices]
/// - [Turn On Bluetooth]
/// - [Open Settings]
/// - [Wi-Fi Settings]
/// - [Continue with LAN Only]
class CapabilitySetupBanner extends StatefulWidget {
  final AppContainer container;

  const CapabilitySetupBanner({super.key, required this.container});

  @override
  State<CapabilitySetupBanner> createState() => _CapabilitySetupBannerState();
}

class _CapabilitySetupBannerState extends State<CapabilitySetupBanner> {
  bool _dismissedBleWarning = false;
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<EvaluatedCapabilityState>(
      stream: widget.container.capabilityCoordinator.stateStream,
      initialData: widget.container.capabilityCoordinator.state,
      builder: (context, snapshot) {
        final state =
            snapshot.data ?? widget.container.capabilityCoordinator.state;
        final caps = state.capabilities;

        // If both transports are ready or BLE is ready and LAN is dismissed, no banner needed.
        if (state.operationalStatus == CapabilityOperationalStatus.readyBoth) {
          return const SizedBox.shrink();
        }

        // If BLE is not ready, but LAN is ready and user chose to continue with LAN only:
        if (state.operationalStatus ==
                CapabilityOperationalStatus.readyLanOnly &&
            (_dismissedBleWarning || state.lanOnlyDismissed)) {
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);

        // Case 1: Both LAN and BLE are completely unavailable
        if (!state.canUseLan && !state.canUseBle) {
          return _buildCriticalBanner(context, theme, caps);
        }

        // Case 2: LAN is available, but BLE is missing permissions or disabled
        if (state.canUseLan &&
            !state.canUseBle &&
            !_dismissedBleWarning &&
            !state.lanOnlyDismissed) {
          return _buildBleWarningBanner(context, theme, caps);
        }

        // Case 3: BLE is ready, but LAN is disconnected (e.g. cellular or offline)
        if (!state.canUseLan && state.canUseBle) {
          return _buildLanNoticeBanner(context, theme, caps);
        }

        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildCriticalBanner(
    BuildContext context,
    ThemeData theme,
    SystemCapabilities caps,
  ) {
    final String title;
    final String explanation;
    final List<Widget> actions = [];

    if (caps.isBluetoothOff && caps.lanState == NetworkState.disconnected) {
      title = 'No Transports Available';
      explanation = 'Vayu cannot discover nearby devices because Wi-Fi is disconnected and Bluetooth is turned off.';
      actions.add(
        FilledButton.tonalIcon(
          onPressed: _isProcessing
              ? null
              : () => _handleAction(
                  () =>
                      widget.container.capabilityCoordinator.enableBluetooth(),
                ),
          icon: const Icon(Icons.bluetooth_rounded, size: 16),
          label: const Text('Turn On Bluetooth'),
        ),
      );
      actions.add(
        OutlinedButton.icon(
          onPressed: () =>
              widget.container.capabilityCoordinator.openWifiSettings(),
          icon: const Icon(Icons.wifi_rounded, size: 16),
          label: const Text('Connect to Wi-Fi'),
        ),
      );
    } else if (caps.isNearbyPermissionMissing &&
        caps.lanState == NetworkState.disconnected) {
      title = 'Nearby Permission Required';
      explanation = 'Wi-Fi is disconnected, and Vayu requires Nearby device access to discover phones via Bluetooth.';
      if (caps.isPermanentlyDenied) {
        actions.add(
          FilledButton.icon(
            onPressed: () =>
                widget.container.capabilityCoordinator.openAppSettings(),
            icon: const Icon(Icons.settings_rounded, size: 16),
            label: const Text('Open Settings'),
          ),
        );
      } else {
        actions.add(
          FilledButton.icon(
            onPressed: _isProcessing ? null : _requestNearbyPermission,
            icon: const Icon(Icons.security_rounded, size: 16),
            label: const Text('Allow Nearby Devices'),
          ),
        );
      }
      actions.add(
        OutlinedButton.icon(
          onPressed: () => widget.container.platformService.openWifiSettings(),
          icon: const Icon(Icons.wifi_rounded, size: 16),
          label: const Text('Connect to Wi-Fi'),
        ),
      );
    } else {
      title = 'Connectivity Required';
      explanation = 'Connect to a local Wi-Fi network or enable Bluetooth to discover nearby devices.';
      actions.add(
        OutlinedButton.icon(
          onPressed: () => widget.container.platformService.openWifiSettings(),
          icon: const Icon(Icons.wifi_rounded, size: 16),
          label: const Text('Wi-Fi Settings'),
        ),
      );
    }

    return _buildContainer(
      theme: theme,
      borderColor: Colors.red.shade300,
      backgroundColor: Colors.red.shade50,
      icon: Icons.signal_cellular_connected_no_internet_0_bar_rounded,
      iconColor: Colors.red.shade700,
      title: title,
      explanation: explanation,
      actions: actions,
    );
  }

  Widget _buildBleWarningBanner(
    BuildContext context,
    ThemeData theme,
    SystemCapabilities caps,
  ) {
    final String title;
    final String explanation;
    final List<Widget> actions = [];

    if (caps.isBluetoothOff) {
      title = 'Bluetooth is Turned Off';
      explanation = 'Local Wi-Fi is ready for sharing. To also discover phones via Bluetooth Low Energy, turn on Bluetooth.';
      actions.add(
        FilledButton.tonalIcon(
          onPressed: _isProcessing
              ? null
              : () => _handleAction(
                  () =>
                      widget.container.capabilityCoordinator.enableBluetooth(),
                ),
          icon: const Icon(Icons.bluetooth_rounded, size: 16),
          label: const Text('Turn On Bluetooth'),
        ),
      );
    } else if (caps.isNearbyPermissionMissing) {
      title = 'Nearby Device Access';
      explanation = 'Nearby device access allows Vayu to discover phones over Bluetooth Low Energy. Your location is never tracked.';
      if (caps.isPermanentlyDenied) {
        actions.add(
          FilledButton.icon(
            onPressed: () =>
                widget.container.capabilityCoordinator.openAppSettings(),
            icon: const Icon(Icons.settings_rounded, size: 16),
            label: const Text('Open Settings'),
          ),
        );
      } else {
        actions.add(
          FilledButton.icon(
            onPressed: _isProcessing ? null : _requestNearbyPermission,
            icon: const Icon(Icons.security_rounded, size: 16),
            label: const Text('Allow Permission'),
          ),
        );
      }
    } else {
      title = 'BLE Unavailable';
      explanation = 'Bluetooth Low Energy is currently unavailable. You can continue using Wi-Fi LAN discovery.';
    }

    // Always offer choice to proceed with LAN only
    actions.add(
      TextButton(
        onPressed: () {
          widget.container.capabilityCoordinator.continueWithLanOnly();
          setState(() => _dismissedBleWarning = true);
        },
        child: const Text('Continue with LAN Only'),
      ),
    );

    return _buildContainer(
      theme: theme,
      borderColor: Colors.amber.shade300,
      backgroundColor: Colors.amber.shade50,
      icon: Icons.info_outline_rounded,
      iconColor: Colors.amber.shade900,
      title: title,
      explanation: explanation,
      actions: actions,
    );
  }

  Widget _buildLanNoticeBanner(
    BuildContext context,
    ThemeData theme,
    SystemCapabilities caps,
  ) {
    return _buildContainer(
      theme: theme,
      borderColor: Colors.blue.shade200,
      backgroundColor: Colors.blue.shade50,
      icon: Icons.wifi_off_rounded,
      iconColor: Colors.blue.shade800,
      title: 'Local Wi-Fi Disconnected',
      explanation: 'Bluetooth discovery is active. Connecting to the same Wi-Fi network enables high-speed transfers.',
      actions: [
        OutlinedButton.icon(
          onPressed: () =>
              widget.container.capabilityCoordinator.openWifiSettings(),
          icon: const Icon(Icons.wifi_rounded, size: 16),
          label: const Text('Wi-Fi Settings'),
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ],
    );
  }

  Widget _buildContainer({
    required ThemeData theme,
    required Color borderColor,
    required Color backgroundColor,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String explanation,
    required List<Widget> actions,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16.0),
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: iconColor, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                            Icons.help_outline_rounded,
                            size: 18,
                            color: iconColor,
                          ),
                          tooltip: 'Permission Rationale',
                          onPressed: () =>
                              PermissionsRationaleDialog.show(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      explanation,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }

  Future<void> _requestNearbyPermission() async {
    setState(() => _isProcessing = true);
    try {
      final status = await widget.container.capabilityCoordinator
          .requestNearbyAccess();
      if (status == PermissionStatus.permanentlyDenied && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Permission permanently denied. Please enable Nearby devices in App Settings.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _handleAction(Future<dynamic> Function() action) async {
    setState(() => _isProcessing = true);
    try {
      await action();
      await widget.container.capabilityCoordinator.refresh();
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }
}
