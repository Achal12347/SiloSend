import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/nfc_pairing_service.dart';
import 'package:vayu/core/permissions/permission_manager.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_batch.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/pairing/pairing_page.dart';
import 'package:vayu/ui/pairing/qr_code_view.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/widgets/info_dot.dart';
import 'package:vayu/ui/widgets/nfc_off_row.dart';
import 'package:vayu/ui/widgets/permission_flow.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// "Ready to receive": this phone is visible, shows a one-time code (QR and
/// NFC), and accepts files without a prompt from a phone that scanned or
/// tapped that code while this screen is open. Anyone else still gets the
/// normal Accept / Decline sheet.
class ReceivePage extends StatefulWidget {
  final AppContainer container;

  /// How long one code stays valid.
  final Duration sessionLength;

  const ReceivePage({
    super.key,
    required this.container,
    this.sessionLength = const Duration(minutes: 10),
  });

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReceivePage(container: container)),
      );

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> with WidgetsBindingObserver {
  PairingPayload? _payload;
  bool _preparing = true;
  bool _useHotspot = false;
  String? _problem;

  /// Why the direct connection failed, when the user can fix it (a
  /// permission or Location); fixed on return from Settings, the code is
  /// prepared again by itself.
  HotspotStartError? _fixable;
  bool _nfcReady = false;
  bool _nfcOff = false;
  DateTime? _endsAt;
  Timer? _ticker;
  StreamSubscription<TransferBatch>? _acceptedSub;

  AppContainer get _c => widget.container;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Offers are welcome while this screen is open, code or no code.
    _c.fileSharingCoordinator.openReceiveScreen();
    _acceptedSub = _c.fileSharingCoordinator.autoAcceptedBatches.listen(
      _onAccepted,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Back from the NFC settings page: serve the code by tap now.
    final payload = _payload;
    if (payload != null && !_nfcReady) {
      _serveByTap(payload);
    }
    // Back from Settings after allowing what the direct connection needed.
    if (_fixable != null && !_preparing) _retryIfFixed();
  }

  Future<void> _retryIfFixed() async {
    final blockers = await _c.permissionManager.check(VayuFeature.directWifi);
    if (mounted && blockers.isEmpty && _fixable != null) _start();
  }

  /// "Fix" on the problem line: explain, allow, then prepare the code again.
  Future<void> _fix() async {
    if (await ensureFeature(context, _c, VayuFeature.directWifi)) _start();
  }

  Future<void> _serveByTap(PairingPayload payload) async {
    final nfc = await _c.nfcPairingService.writePayload(payload);
    if (!mounted) return;
    setState(() {
      _nfcReady = nfc.isSuccess;
      _nfcOff = nfc.status == NfcOperationStatus.hardwareDisabled;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _acceptedSub?.cancel();
    try {
      _c.releaseDiscovery(this);
      _c.fileSharingCoordinator.closeReceiveScreen();
      _c.fileSharingCoordinator.endReceiveSession();
      _c.nfcPairingService.stopSharing();
      _c.pairingCoordinator.releaseHotspotWhenIdle();
    } on StateError {
      // The container was already disposed (app shutdown).
    }
    super.dispose();
  }

  Future<void> _start() async {
    if (!mounted) return;
    setState(() {
      _preparing = true;
      _problem = null;
      _fixable = null;
    });
    try {
      // Being findable is the point of this screen: explain and ask once.
      final raw = _c.capabilityCoordinator.rawCapabilities;
      if (raw.isNearbyPermissionNotRequested) {
        await ensureFeature(context, _c, VayuFeature.findPhones);
      }
      // Stay findable for as long as this screen is open.
      _c.holdDiscovery(this);

      // A direct connection is needed without a shared Wi-Fi, or when the
      // user asked for one: explain its permission before Android asks.
      // On a shared Wi-Fi it is only an extra, tried when already allowed.
      final needDirect = _useHotspot || !raw.canUseLan;
      // Phones that find this one over Bluetooth (not on the same Wi-Fi)
      // send over a Wi-Fi Direct group this phone hosts: explain and ask
      // once while the user is here to receive.
      var askForBluetoothSenders = false;
      if (_c.wifiDirectSupported) {
        final report = await _c.permissionManager.refresh();
        final group = PermissionManager.groupFor(
          VayuFeature.directWifi,
          report.sdkVersion ?? 0,
        );
        askForBluetoothSenders =
            group != null &&
            _c.permissionManager.stateOf(group, report) ==
                PermissionState.notRequested;
      }
      if ((needDirect || askForBluetoothSenders) && mounted) {
        await ensureFeature(context, _c, VayuFeature.directWifi);
      }
      final directReady = (await _c.permissionManager.check(
        VayuFeature.directWifi,
      )).isEmpty;

      final (payload, hotspotError) = await _c.pairingCoordinator
          .prepareShowableCode(
            forceHotspot: _useHotspot,
            tryWifiDirect: needDirect || directReady,
          );
      if (hotspotError != null) {
        _problem = _hotspotProblem(hotspotError);
        if (hotspotError == HotspotStartError.permissionDenied ||
            hotspotError == HotspotStartError.locationOff) {
          _fixable = hotspotError;
        }
      }
      if (payload != null) {
        _c.fileSharingCoordinator.startReceiveSession(
          payload.pairingToken,
          lifetime: widget.sessionLength,
        );
        final nfc = await _c.nfcPairingService.writePayload(payload);
        _nfcReady = nfc.isSuccess;
        _nfcOff = nfc.status == NfcOperationStatus.hardwareDisabled;
        _endsAt = DateTime.now().add(widget.sessionLength);
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      } else {
        _problem ??= 'Connect to Wi-Fi, or use a direct connection, so the other phone can reach this one.';
      }
      if (mounted) setState(() => _payload = payload);
    } catch (e) {
      AppLogger.warning('Receive', 'Preparing the receive code failed: $e');
      if (mounted) setState(() => _problem = friendlyError(e));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  void _tick() {
    if (!mounted) return;
    final ends = _endsAt;
    if (ends != null && DateTime.now().isAfter(ends)) {
      // The code expired: stop accepting without a prompt.
      _ticker?.cancel();
      _c.fileSharingCoordinator.endReceiveSession();
      _c.nfcPairingService.stopSharing();
      setState(() {
        _payload = null;
        _endsAt = null;
      });
      return;
    }
    setState(() {});
  }

  void _onAccepted(TransferBatch batch) {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    TransferDetailPage.open(context, _c, batchId: batch.batchId);
  }

  String _hotspotProblem(HotspotStartError error) => switch (error) {
    HotspotStartError.permissionDenied =>
      'Allow "Nearby devices" so Vayu can create a direct connection.',
    HotspotStartError.locationOff =>
      'Turn on Location. Android needs it to create a direct connection.',
    HotspotStartError.tetheringActive =>
      'Turn off your mobile hotspot, then try again.',
    HotspotStartError.unsupported =>
      'This phone cannot create a direct connection.',
    HotspotStartError.failed =>
      'Could not create a direct connection. Try again in a moment.',
  };

  String _remaining() {
    final ends = _endsAt;
    if (ends == null) return '';
    final left = ends.difference(DateTime.now());
    final m = left.inMinutes;
    final s = (left.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _c.identity?.displayName ?? 'This phone';
    final payload = _payload;
    final expired = !_preparing && payload == null && _problem == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Center(
              child: DeviceAvatar(
                name: name,
                seed: _c.identity?.idHex ?? name,
                size: 64,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Visible as $name',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            if (payload != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _nfcReady
                        ? 'Tap or scan to send here'
                        : 'Scan to send here',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  InfoDot(
                    title: 'Receiving',
                    message: _nfcReady
                        ? "Touch this phone to the sender's Send screen, or let them scan this code. Files are accepted automatically while this screen is open."
                        : 'Let the sender scan this code. Files are accepted automatically while this screen is open.',
                  ),
                ],
              ),
            if (payload != null && _nfcOff) ...[
              const SizedBox(height: 8),
              NfcOffRow(container: _c),
            ],
            if (payload != null) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.circle,
                    size: 8,
                    color: VayuPalette.of(context).success,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Waiting for a sender…',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            Center(
              child: SizedBox(
                width: 260,
                height: 260,
                child: _preparing
                    ? const Center(child: CircularProgressIndicator())
                    : payload != null
                    ? QrCodeView(
                        data: payload.toUri().toString(),
                        semanticLabel: 'Code to send files to this phone',
                      )
                    : Center(
                        child: Icon(
                          Icons.qr_code_2_rounded,
                          size: 96,
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            if (payload != null && _endsAt != null)
              Text(
                'Ready for ${_remaining()}',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.secondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            if (_problem != null) ...[
              const SizedBox(height: 8),
              Text(
                _problem!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (expired) ...[
              Text(
                'This code has expired.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 24),
            if (_fixable != null)
              FilledButton(
                onPressed: _preparing ? null : _fix,
                child: Text(
                  _fixable == HotspotStartError.locationOff
                      ? 'Turn on Location'
                      : 'Allow',
                ),
              )
            else if (expired || _problem != null)
              FilledButton(
                onPressed: _preparing ? null : _start,
                child: const Text('Start again'),
              ),
            // A Wi-Fi Direct code already works without shared Wi-Fi.
            if (!_useHotspot && !_preparing && !(_payload?.wifiDirect ?? false))
              TextButton(
                onPressed: () {
                  setState(() => _useHotspot = true);
                  _start();
                },
                child: const Text('Not on the same Wi-Fi?'),
              ),
            TextButton(
              onPressed: () => PairingPage.open(context, _c),
              child: const Text('Other ways to connect'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
