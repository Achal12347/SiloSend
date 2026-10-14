import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_batch.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/pairing/pairing_page.dart';
import 'package:vayu/ui/pairing/qr_code_view.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
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

class _ReceivePageState extends State<ReceivePage> {
  PairingPayload? _payload;
  bool _preparing = true;
  bool _useHotspot = false;
  String? _problem;
  bool _nfcReady = false;
  DateTime? _endsAt;
  Timer? _ticker;
  StreamSubscription<TransferBatch>? _acceptedSub;

  AppContainer get _c => widget.container;

  @override
  void initState() {
    super.initState();
    _acceptedSub = _c.fileSharingCoordinator.autoAcceptedBatches.listen(
      _onAccepted,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _acceptedSub?.cancel();
    try {
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
    });
    try {
      // Being findable is the point of this screen.
      final raw = _c.capabilityCoordinator.rawCapabilities;
      if (raw.isNearbyPermissionNotRequested) {
        await _c.capabilityCoordinator.requestNearbyAccess();
      }
      if (_c.discoveryStatus == DiscoveryStatus.idle &&
          _c.capabilityCoordinator.state.hasAnyReady) {
        await _c.startDiscoveryAndAdvertising();
      }

      final (payload, hotspotError) = await _c.pairingCoordinator
          .prepareShowableCode(forceHotspot: _useHotspot);
      if (hotspotError != null) _problem = _hotspotProblem(hotspotError);
      if (payload != null) {
        _c.fileSharingCoordinator.startReceiveSession(
          payload.pairingToken,
          lifetime: widget.sessionLength,
        );
        final nfc = await _c.nfcPairingService.writePayload(payload);
        _nfcReady = nfc.isSuccess;
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
            Text(
              payload != null
                  ? (_nfcReady
                        ? 'Tap phones or scan this code to send here.'
                        : 'Scan this code on the other phone to send here.')
                  : ' ',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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
            if (expired || _problem != null)
              FilledButton(
                onPressed: _preparing ? null : _start,
                child: const Text('Start again'),
              ),
            if (!_useHotspot && !_preparing)
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
