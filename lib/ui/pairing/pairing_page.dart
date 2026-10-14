import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/platform/qr_scanner.dart';
import 'package:vayu/ui/pairing/qr_code_view.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/friendly_error.dart';

enum PairingMode { show, join }

/// Pair two phones by QR code, NFC tap or pairing link (Phase 5 OOB pairing).
///
/// Show: a QR code (and NFC card emulation) carrying this phone's address,
/// identity key and a one-time secret. When the phones share no Wi-Fi, a
/// phone-to-phone hotspot is started and its credentials go into the code.
/// Join: scan, tap or paste; the [PairingCoordinator] verifies the key out of
/// band, joins the hotspot if needed and connects.
class PairingPage extends StatefulWidget {
  final AppContainer container;
  final PairingMode initialMode;

  /// Test hook replacing the native camera scanner.
  final Future<String?> Function()? scanOverride;

  const PairingPage({
    super.key,
    required this.container,
    this.initialMode = PairingMode.show,
    this.scanOverride,
  });

  /// Opens the page; completes with the paired peer, or null.
  static Future<DiscoveredPeer?> open(
    BuildContext context,
    AppContainer container, {
    PairingMode mode = PairingMode.show,
  }) {
    return Navigator.of(context).push<DiscoveredPeer>(
      MaterialPageRoute(
        builder: (_) => PairingPage(container: container, initialMode: mode),
      ),
    );
  }

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  late PairingMode _mode = widget.initialMode;

  // Show side
  PairingPayload? _payload;
  bool _useHotspot = false;
  bool _preparing = true;
  String? _showProblem;
  bool _offerLocationSettings = false;
  bool _nfcReady = false;
  StreamSubscription<List<ConnectionSession>>? _sessionSub;
  int _sessionsAtOpen = 0;

  // Join side
  final TextEditingController _linkController = TextEditingController();
  bool _joining = false;
  String? _joinProblem;
  StreamSubscription<PairingPayload>? _nfcPayloadSub;

  AppContainer get _c => widget.container;

  @override
  void initState() {
    super.initState();
    _checkNfc();
    _sessionsAtOpen = _c.activeSessions.length;
    _sessionSub = _c.activeSessionsStream.listen(_onSessionsChanged);
    // setState is not allowed inside initState; start once the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _enterMode(_mode);
    });
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _nfcPayloadSub?.cancel();
    _linkController.dispose();
    try {
      // Stop serving the code over NFC and let the hotspot wind down.
      _c.nfcPairingService.stopSharing();
      _c.nfcPairingService.stopListening();
      _c.pairingCoordinator.releaseHotspotWhenIdle();
    } on StateError {
      // The container was already disposed (app shutdown); nothing to release.
    }
    super.dispose();
  }

  Future<void> _checkNfc() async {
    final nfc = _c.nfcPairingService;
    final ready = await nfc.isNfcAvailable && await nfc.isNfcEnabled;
    if (mounted) setState(() => _nfcReady = ready);
  }

  Future<void> _enterMode(PairingMode mode) async {
    setState(() => _mode = mode);
    if (mode == PairingMode.show) {
      await _c.nfcPairingService.stopListening();
      await _nfcPayloadSub?.cancel();
      await _prepareCode();
    } else {
      await _c.nfcPairingService.stopSharing();
      _nfcPayloadSub ??= _c.nfcPairingService.onPayloadReceived.listen(
        (payload) => _join(() => _c.pairingCoordinator.join(payload)),
      );
      await _c.nfcPairingService.startReading();
    }
  }

  // ------------------------------------------------------------- show side

  Future<void> _prepareCode() async {
    setState(() {
      _preparing = true;
      _showProblem = null;
      _offerLocationSettings = false;
    });
    try {
      HotspotCredentials? credentials;
      var payload = await _c.pairingCoordinator.buildLocalPayload();
      // No shared network address: a direct phone-to-phone network is needed.
      if (payload.lanAddress == null) _useHotspot = true;
      if (_useHotspot) {
        final started = await _c.pairingCoordinator.startHotspot();
        if (started.isSuccess) {
          credentials = started.credentials;
          payload = await _c.pairingCoordinator.buildLocalPayload(
            hotspotCredentials: credentials,
          );
        } else {
          _explainHotspotFailure(started.error!);
        }
      }
      await _c.nfcPairingService.writePayload(payload);
      if (mounted) setState(() => _payload = payload);
    } on PairingException catch (e) {
      if (mounted) setState(() => _showProblem = e.message);
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  void _explainHotspotFailure(HotspotStartError error) {
    _offerLocationSettings = error == HotspotStartError.locationOff;
    _showProblem = switch (error) {
      HotspotStartError.permissionDenied => 'Allow "Nearby devices" (or Location on older Android) so Vayu can create a direct Wi-Fi connection.',
      HotspotStartError.locationOff => 'Turn on Location. Android needs it to create a direct Wi-Fi connection on this version.',
      HotspotStartError.tetheringActive =>
        'Turn off your mobile hotspot, then try again.',
      HotspotStartError.unsupported =>
        'This phone cannot create a direct Wi-Fi connection.',
      HotspotStartError.failed =>
        'Could not create a direct Wi-Fi connection. Try again in a moment.',
    };
  }

  void _onSessionsChanged(List<ConnectionSession> sessions) {
    // Someone joined while our code was on screen: pairing is done here too.
    if (_mode == PairingMode.show &&
        sessions.length > _sessionsAtOpen &&
        mounted) {
      final name = sessions.last.info.remoteDisplayName ?? 'a nearby device';
      showVayuNotice(
        context,
        'Connected to $name',
        tone: VayuNoticeTone.success,
      );
      Navigator.of(context).maybePop();
    }
  }

  // ------------------------------------------------------------- join side

  Future<void> _scan() async {
    try {
      final text = await (widget.scanOverride ?? const QrScanner().scan)();
      if (text == null) return;
      await _join(() => _c.pairingCoordinator.joinFromText(text));
    } on QrScanException catch (e) {
      setState(() {
        _joinProblem = switch (e.error) {
          QrScanError.permissionDenied =>
            'Camera access is needed to scan. You can paste the link instead.',
          QrScanError.cameraUnavailable => 'The camera could not be opened.',
          QrScanError.unsupported =>
            'Scanning is not available on this device.',
        };
      });
    }
  }

  Future<void> _join(Future<DiscoveredPeer> Function() action) async {
    if (_joining) return;
    setState(() {
      _joining = true;
      _joinProblem = null;
    });
    try {
      final peer = await action();
      if (!mounted) return;
      showVayuNotice(
        context,
        'Paired with ${peer.displayName}',
        tone: VayuNoticeTone.success,
      );
      Navigator.of(context).pop(peer);
    } on PairingException catch (e) {
      if (mounted) setState(() => _joinProblem = e.message);
    } catch (e) {
      if (mounted) setState(() => _joinProblem = friendlyError(e));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair a phone')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: [
            SegmentedButton<PairingMode>(
              segments: const [
                ButtonSegment(
                  value: PairingMode.show,
                  icon: Icon(Icons.qr_code_2_rounded),
                  label: Text('Show code'),
                ),
                ButtonSegment(
                  value: PairingMode.join,
                  icon: Icon(Icons.qr_code_scanner_rounded),
                  label: Text('Join'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => _enterMode(s.first),
            ),
            const SizedBox(height: 24),
            if (_mode == PairingMode.show)
              ..._buildShow(context)
            else
              ..._buildJoin(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildShow(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final payload = _payload;
    final link = payload?.toUri().toString();

    return [
      Center(
        child: _preparing
            ? SizedBox(
                width: 260,
                height: 260,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 14),
                      Text(
                        _useHotspot
                            ? 'Creating a direct Wi-Fi…'
                            : 'Preparing code…',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              )
            : link == null || payload?.lanAddress == null
            ? const SizedBox.shrink()
            : QrCodeView(data: link),
      ),
      const SizedBox(height: 20),
      if (payload != null)
        Text(
          payload.displayName,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge,
        ),
      const SizedBox(height: 6),
      Text(
        'Open Vayu on the other phone, tap Join and scan this code.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      if (_nfcReady) ...[
        const SizedBox(height: 14),
        _HintRow(
          icon: Icons.contactless_rounded,
          text: 'Or hold the two phones back to back',
          color: palette.accent,
        ),
      ],
      if (payload?.wifiSsid != null) ...[
        const SizedBox(height: 14),
        _HintRow(
          icon: Icons.wifi_tethering_rounded,
          text: 'Direct Wi-Fi "${payload!.wifiSsid}" is on while you pair',
          color: palette.accent,
        ),
      ],
      if (_showProblem != null) ...[
        const SizedBox(height: 16),
        _Problem(text: _showProblem!),
        if (_offerLocationSettings)
          TextButton(
            onPressed: () => _c.platformService.openLocationSettings(),
            child: const Text('Open Location settings'),
          ),
      ],
      const SizedBox(height: 20),
      Card(
        child: SwitchListTile(
          value: _useHotspot,
          onChanged: _preparing
              ? null
              : (value) {
                  setState(() => _useHotspot = value);
                  if (!value) _c.hotspotService.stop();
                  _prepareCode();
                },
          title: const Text('Not on the same Wi-Fi?'),
          subtitle: const Text(
            'Create a direct phone-to-phone Wi-Fi for fast transfers',
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (link != null && payload?.lanAddress != null)
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) {
              showVayuNotice(context, 'Link copied');
            }
          },
          icon: const Icon(Icons.link_rounded),
          label: const Text('Copy pairing link'),
        ),
    ];
  }

  List<Widget> _buildJoin(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return [
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          gradient: palette.heroGradient,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: palette.heroBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.qr_code_scanner_rounded,
              color: palette.heroGlow,
              size: 32,
            ),
            const SizedBox(height: 14),
            Text(
              'Scan the code on the other phone',
              style: theme.textTheme.titleLarge?.copyWith(
                color: palette.onHero,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'On that phone, open Pair a phone and choose Show code.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.onHeroMuted,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _joining ? null : _scan,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.onHero,
                  foregroundColor: const Color(0xFF1A1B1E),
                ),
                icon: _joining
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Icon(Icons.photo_camera_outlined),
                label: Text(_joining ? 'Connecting…' : 'Scan code'),
              ),
            ),
          ],
        ),
      ),
      if (_nfcReady) ...[
        const SizedBox(height: 16),
        _HintRow(
          icon: Icons.contactless_rounded,
          text: 'Or hold the phones back to back to pair by NFC',
          color: palette.accent,
        ),
      ],
      const SizedBox(height: 28),
      Text('Have a pairing link?', style: theme.textTheme.titleSmall),
      const SizedBox(height: 10),
      TextField(
        controller: _linkController,
        minLines: 1,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: 'vayu://pair?…',
          prefixIcon: Icon(Icons.link_rounded),
        ),
      ),
      const SizedBox(height: 10),
      OutlinedButton(
        onPressed: _joining
            ? null
            : () => _join(
                () => _c.pairingCoordinator.joinFromText(_linkController.text),
              ),
        child: const Text('Join with link'),
      ),
      if (_joinProblem != null) ...[
        const SizedBox(height: 16),
        _Problem(text: _joinProblem!),
      ],
    ];
  }
}

class _HintRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _HintRow({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  final String text;

  const _Problem({required this.text});

  @override
  Widget build(BuildContext context) {
    final palette = VayuPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.dangerContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: palette.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
