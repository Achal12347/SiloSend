import 'package:flutter/material.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/core/capabilities/capability_coordinator.dart';
import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/domain/identity/permission_report.dart';
import 'package:vayu/ui/settings/permissions_page.dart';
import 'package:vayu/ui/widgets/permission_flow.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

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
      title = "Can't find phones yet";
      explanation = 'Connect to Wi-Fi or turn on Bluetooth.';
      actions.add(
        FilledButton.tonalIcon(
          onPressed: _isProcessing ? null : _turnOnBluetooth,
          icon: const Icon(Icons.bluetooth_rounded, size: 16),
          label: const Text('Turn on Bluetooth'),
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
      title = 'Allow nearby devices';
      explanation = 'Vayu needs this to find phones over Bluetooth.';
      if (caps.isPermanentlyDenied) {
        actions.add(
          FilledButton.icon(
            onPressed: _isProcessing ? null : _fixNearby,
            icon: const Icon(Icons.settings_rounded, size: 16),
            label: const Text('Open settings'),
          ),
        );
      } else {
        actions.add(
          FilledButton.icon(
            onPressed: _isProcessing ? null : _requestNearbyPermission,
            icon: const Icon(Icons.security_rounded, size: 16),
            label: const Text('Allow'),
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
    } else if (_locationBlocksBluetooth(caps)) {
      title = "Can't find phones yet";
      explanation = _locationExplanation(caps);
      actions.add(_turnOnLocationButton());
      actions.add(
        OutlinedButton.icon(
          onPressed: () => widget.container.platformService.openWifiSettings(),
          icon: const Icon(Icons.wifi_rounded, size: 16),
          label: const Text('Connect to Wi-Fi'),
        ),
      );
    } else {
      title = 'Connect to Wi-Fi or Bluetooth';
      explanation = 'Vayu finds phones on your Wi-Fi or over Bluetooth.';
      actions.add(
        OutlinedButton.icon(
          onPressed: () => widget.container.platformService.openWifiSettings(),
          icon: const Icon(Icons.wifi_rounded, size: 16),
          label: const Text('Wi-Fi settings'),
        ),
      );
    }

    return _buildContainer(
      theme: theme,
      borderColor: VayuPalette.fromTheme(theme).dangerContainer,
      backgroundColor: VayuPalette.fromTheme(theme).dangerContainer,
      icon: Icons.signal_cellular_connected_no_internet_0_bar_rounded,
      iconColor: VayuPalette.fromTheme(theme).danger,
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
      title = 'Bluetooth is off';
      explanation = "Turn it on to also find phones that aren't on your Wi-Fi.";
      actions.add(
        FilledButton.tonalIcon(
          onPressed: _isProcessing ? null : _turnOnBluetooth,
          icon: const Icon(Icons.bluetooth_rounded, size: 16),
          label: const Text('Turn on Bluetooth'),
        ),
      );
    } else if (caps.isNearbyPermissionMissing) {
      title = 'Allow nearby devices';
      explanation = 'Lets Vayu find phones over Bluetooth. Your location is never tracked.';
      if (caps.isPermanentlyDenied) {
        actions.add(
          FilledButton.icon(
            onPressed: _isProcessing ? null : _fixNearby,
            icon: const Icon(Icons.settings_rounded, size: 16),
            label: const Text('Open settings'),
          ),
        );
      } else {
        actions.add(
          FilledButton.icon(
            onPressed: _isProcessing ? null : _requestNearbyPermission,
            icon: const Icon(Icons.security_rounded, size: 16),
            label: const Text('Allow'),
          ),
        );
      }
    } else if (_locationBlocksBluetooth(caps)) {
      title = 'Location is off';
      explanation = _locationExplanation(caps);
      actions.add(_turnOnLocationButton());
    } else {
      title = "Bluetooth isn't available";
      explanation = 'You can still share with phones on your Wi-Fi.';
    }

    // Always offer choice to proceed with LAN only
    actions.add(
      TextButton(
        onPressed: () {
          widget.container.capabilityCoordinator.continueWithLanOnly();
          setState(() => _dismissedBleWarning = true);
        },
        child: const Text('Use Wi-Fi only'),
      ),
    );

    return _buildContainer(
      theme: theme,
      borderColor: VayuPalette.fromTheme(theme).warningContainer,
      backgroundColor: VayuPalette.fromTheme(theme).warningContainer,
      icon: Icons.info_outline_rounded,
      iconColor: VayuPalette.fromTheme(theme).warning,
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
      borderColor: theme.colorScheme.primaryContainer,
      backgroundColor: theme.colorScheme.primaryContainer,
      icon: Icons.wifi_off_rounded,
      iconColor: theme.colorScheme.primary,
      title: 'Not on Wi-Fi',
      explanation: 'Join the same Wi-Fi as the other phone for fast transfers.',
      actions: [
        OutlinedButton.icon(
          onPressed: () =>
              widget.container.capabilityCoordinator.openWifiSettings(),
          icon: const Icon(Icons.wifi_rounded, size: 16),
          label: const Text('Wi-Fi settings'),
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
        borderRadius: BorderRadius.circular(20),
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
                            // Theme text colour: readable in light and dark.
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
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
                          tooltip: 'Permissions & settings',
                          onPressed: () =>
                              PermissionsPage.open(context, widget.container),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      explanation,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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

  // The banner already says why, so Allow shows the system dialog at once.
  // If Android will not ask any more, the sheet explains and opens the
  // exact page, then re-checks when the user comes back.
  Future<void> _requestNearbyPermission() => _runFlow(alreadyExplained: true);

  Future<void> _fixNearby() => _runFlow(alreadyExplained: false);

  Future<void> _runFlow({required bool alreadyExplained}) async {
    setState(() => _isProcessing = true);
    try {
      await ensureFeature(
        context,
        widget.container,
        VayuFeature.findPhones,
        alreadyExplained: alreadyExplained,
      );
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  /// Before Android 12, Bluetooth scans find nothing while Location is off.
  static bool _locationBlocksBluetooth(SystemCapabilities caps) =>
      caps.locationRequiredForBle &&
      !caps.locationEnabled &&
      !caps.isBluetoothOff &&
      !caps.isNearbyPermissionMissing &&
      caps.bluetoothState != RadioState.unsupported;

  static String _locationExplanation(SystemCapabilities caps) {
    final version = PermissionManager.androidVersionName(caps.sdkVersion ?? 0);
    final android = version.isEmpty ? 'Android' : 'Android $version';
    return '$android only finds Bluetooth devices while Location is on. Vayu never reads your location.';
  }

  Widget _turnOnLocationButton() => FilledButton.tonalIcon(
    onPressed: () => widget.container.permissionManager.openSettingsFor(
      const Blocker.switchOff(BlockerKind.locationOff),
    ),
    icon: const Icon(Icons.location_on_outlined, size: 16),
    label: const Text('Turn on Location'),
  );

  /// The system "Turn on Bluetooth?" dialog; when the phone cannot show it,
  /// offers the Bluetooth settings page instead.
  Future<void> _turnOnBluetooth() async {
    setState(() => _isProcessing = true);
    try {
      final on = await widget.container.capabilityCoordinator.enableBluetooth();
      if (!on && mounted) {
        showVayuNotice(
          context,
          'Bluetooth is still off.',
          actionLabel: 'Settings',
          onAction: () => widget.container.platformService.openSettingsPage(
            SettingsPage.bluetooth,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }
}
