import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/security/trust_level.dart';
import 'package:vayu/core/pairing/nfc_pairing_service.dart';
import 'package:vayu/ui/widgets/nfc_off_row.dart';
import 'package:vayu/ui/widgets/camera_access.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/platform/qr_scanner.dart';

/// Modal bottom sheet allowing the user to select a discovered nearby Vayu
/// peer to receive a pre-selected document or batch of documents.
class PeerSelectionSheet extends StatefulWidget {
  final List<SelectedDocument> documents;
  final AppContainer container;

  SelectedDocument get document => documents.first;

  PeerSelectionSheet({
    super.key,
    SelectedDocument? document,
    List<SelectedDocument>? documents,
    required this.container,
  }) : documents =
           documents ??
           (document != null ? [document] : const <SelectedDocument>[]);

  /// Shows the peer selection bottom sheet.
  static Future<void> show(
    BuildContext context, {
    SelectedDocument? document,
    List<SelectedDocument>? documents,
    required AppContainer container,
  }) {
    final docs =
        documents ??
        (document != null ? [document] : const <SelectedDocument>[]);
    if (docs.isEmpty) return Future.value();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) =>
          PeerSelectionSheet(documents: docs, container: container),
    );
  }

  @override
  State<PeerSelectionSheet> createState() => _PeerSelectionSheetState();
}

class _PeerSelectionSheetState extends State<PeerSelectionSheet>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _isSending = false;
  Timer? _pulseStop;
  String? _sendingToPeerId;

  // Tap or scan a phone that is on its Receive screen.
  StreamSubscription<PairingPayload>? _nfcSub;
  StreamSubscription<NfcTapProblem>? _tapProblemSub;
  bool _nfcReady = false;
  bool _nfcOff = false;
  bool _joining = false;

  bool get _nativeNfc =>
      Platform.isAndroid &&
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      !WidgetsBinding.instance.runtimeType.toString().contains('Test');

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    final isTesting =
        Platform.environment.containsKey('FLUTTER_TEST') ||
        WidgetsBinding.instance.runtimeType.toString().contains('Test');
    // A short pulse only, and none with Android's "Remove animations".
    final reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    if (!isTesting && !reduceMotion) {
      _pulseController.repeat(reverse: true);
      _pulseStop = Timer(const Duration(seconds: 8), () {
        if (mounted) _pulseController.animateTo(1.0);
      });
    } else {
      _pulseController.value = 1.0;
    }

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Search for phones for as long as the sheet is open.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final raw = widget.container.capabilityCoordinator.rawCapabilities;
        if (raw.isNearbyPermissionNotRequested) {
          await widget.container.capabilityCoordinator.requestNearbyAccess();
        }
      } catch (_) {}
      if (!mounted) return;
      widget.container.holdDiscovery(this);
      _startTapReading();
    });
  }

  Future<void> _startTapReading() async {
    if (!_nativeNfc || !mounted) return;
    WidgetsBinding.instance.addObserver(this);
    final nfc = widget.container.nfcPairingService;
    _nfcSub ??= nfc.onPayloadReceived.listen(
      (payload) => _sendToReceiver(
        () => widget.container.pairingCoordinator.joinToSend(payload),
      ),
    );
    _tapProblemSub ??= nfc.onTapProblem.listen(_onTapProblem);
    await _readTaps();
  }

  Future<void> _readTaps() async {
    final result = await widget.container.nfcPairingService.startReading();
    if (!mounted) return;
    setState(() {
      _nfcReady = result.isSuccess;
      _nfcOff = result.status == NfcOperationStatus.hardwareDisabled;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the NFC settings page.
    if (state == AppLifecycleState.resumed && !_nfcReady) _readTaps();
  }

  void _onTapProblem(NfcTapProblem problem) {
    if (!mounted || _joining) return;
    showVayuNotice(
      context,
      problem == NfcTapProblem.notSharing
          ? 'That phone is not on Receive. Ask them to open Receive, then tap again.'
          : 'Hold the phones together a moment longer.',
    );
  }

  Future<void> _scanReceiver() async {
    if (!await ensureCameraAccess(context, widget.container)) return;
    if (!mounted) return;
    try {
      final text = await const QrScanner().scan();
      if (text == null) return;
      await _sendToReceiver(
        () => widget.container.pairingCoordinator.joinToSendFromText(text),
      );
    } on QrScanException {
      if (mounted) {
        showVayuNotice(
          context,
          'The camera could not be opened.',
          tone: VayuNoticeTone.problem,
        );
      }
    }
  }

  /// Joins the phone whose Receive code was tapped or scanned, then sends.
  /// That phone accepts without a prompt while its Receive screen is open.
  Future<void> _sendToReceiver(Future<DiscoveredPeer> Function() join) async {
    if (_joining || _isSending) return;
    setState(() => _joining = true);
    try {
      final peer = await join();
      if (!mounted) return;
      await _sendToPeer(peer);
    } on PairingException catch (e) {
      if (mounted) {
        showVayuNotice(context, e.message, tone: VayuNoticeTone.problem);
      }
    } catch (e) {
      if (mounted) {
        showVayuNotice(context, friendlyError(e), tone: VayuNoticeTone.problem);
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  void dispose() {
    widget.container.releaseDiscovery(this);
    _pulseStop?.cancel();
    _pulseController.dispose();
    _nfcSub?.cancel();
    _tapProblemSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_nativeNfc) {
      widget.container.nfcPairingService.stopListening().ignore();
    }
    super.dispose();
  }

  String _formatFileSize(int bytes) {
    if (bytes < 0) return 'Unknown size';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  IconData _getFileIcon(String name, String? mime) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_rounded;
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif')) {
      return Icons.image_rounded;
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov')) {
      return Icons.video_file_rounded;
    }
    if (lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.m4a')) {
      return Icons.audio_file_rounded;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.gz') ||
        lower.endsWith('.apk')) {
      return Icons.folder_zip_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  /// The picked folder's name when a whole folder is being sent.
  String? get _folderName => widget.documents.first.folder?.split('/').first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = widget.document;
    final folderName = _folderName;
    final isBatch = widget.documents.length > 1 || folderName != null;
    final totalBatchBytes = widget.documents.fold<int>(
      0,
      (sum, d) => sum + (d.sizeBytes > 0 ? d.sizeBytes : 0),
    );

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        top: 16,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // File Summary Header Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isBatch
                        ? Icons.folder_zip_rounded
                        : _getFileIcon(doc.name, doc.mimeType),
                    color: theme.colorScheme.onPrimaryContainer,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        folderName != null
                            ? '$folderName (${widget.documents.length} ${widget.documents.length == 1 ? 'file' : 'files'})'
                            : isBatch
                            ? '${widget.documents.length} files selected'
                            : doc.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isBatch
                            ? '${_formatFileSize(totalBatchBytes)} total • Batch transfer'
                            : _formatFileSize(doc.sizeBytes),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Peer Selection Prompt
          Row(
            children: [
              Text(
                'Send to',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              StreamBuilder<DiscoveryOperationalState>(
                stream: widget
                    .container
                    .discoveryCoordinator
                    .operationalStateStream,
                initialData:
                    widget.container.discoveryCoordinator.operationalState,
                builder: (context, snapshot) {
                  final state = snapshot.data ?? DiscoveryOperationalState.idle;
                  if (state == DiscoveryOperationalState.searching) {
                    return Row(
                      children: [
                        AnimatedBuilder(
                          animation: _pulseAnimation,
                          builder: (context, child) {
                            return Transform.scale(
                              scale: _pulseAnimation.value,
                              child: child,
                            );
                          },
                          child: Icon(
                            Icons.radar_rounded,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Searching…',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Live Discovered Peers
          StreamBuilder<List<DiscoveredPeer>>(
            stream: widget.container.discoveredPeersStream,
            initialData: widget.container.discoveredPeers,
            builder: (context, snapshot) {
              final peers = snapshot.data ?? [];

              if (peers.isEmpty) {
                return _buildEmptyPeerState(theme);
              }

              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: peers.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final peer = peers[index];
                    return _buildPeerTile(context, theme, peer);
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          _buildTapOrScan(theme),
        ],
      ),
    );
  }

  /// The quickest route: tap or scan a phone that is on its Receive screen.
  Widget _buildTapOrScan(ThemeData theme) {
    final box = Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          _joining
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : Icon(
                  _nfcReady ? Icons.nfc_rounded : Icons.qr_code_scanner_rounded,
                  color: theme.colorScheme.secondary,
                ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _joining
                  ? 'Connecting…'
                  : _nfcReady
                  ? 'Tap or scan a phone on Receive'
                  : 'Scan a phone on Receive',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: _joining || _isSending ? null : _scanReceiver,
            child: const Text('Scan'),
          ),
        ],
      ),
    );
    if (!_nfcOff) return box;
    return Column(
      children: [
        box,
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
          child: NfcOffRow(container: widget.container),
        ),
      ],
    );
  }

  Widget _buildEmptyPeerState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.5,
                ),
              ),
              child: Icon(
                Icons.radar_rounded,
                size: 28,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Looking for nearby Vayu devices...',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Keep both devices close and ensure Vayu is open on the other device.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeerTile(
    BuildContext context,
    ThemeData theme,
    DiscoveredPeer peer,
  ) {
    final isSelectedForSend = _isSending && _sendingToPeerId == peer.deviceId;

    // Resolve security trust level if an authenticated session exists
    final secureSession =
        widget.container.getSecureSession(peer.deviceId) ??
        widget.container.secureSessionManager.getSessionForPeer(peer.deviceId);
    final isSasVerified = secureSession?.trustLevel == TrustLevel.sasVerified;

    final transports = peer.availableTransports.isNotEmpty
        ? peer.availableTransports
        : {peer.transportType};

    return InkWell(
      onTap: _isSending ? null : () => _sendToPeer(peer),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: Text(
                peer.displayName.isNotEmpty
                    ? peer.displayName.substring(0, 1).toUpperCase()
                    : '?',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          peer.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (isSasVerified) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.verified_rounded,
                          size: 15,
                          color: VayuPalette.fromTheme(theme).success,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: transports.map((t) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          t == TransportType.lan ? 'Wi-Fi' : 'Bluetooth',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isSelectedForSend)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              FilledButton.icon(
                onPressed: () => _sendToPeer(peer),
                icon: const Icon(Icons.send_rounded, size: 14),
                label: const Text('Send'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendToPeer(DiscoveredPeer peer) async {
    setState(() {
      _isSending = true;
      _sendingToPeerId = peer.deviceId;
    });

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      // A phone joined through its Receive code gets the files as one batch,
      // carrying the proof that lets it accept without a prompt.
      final viaReceiveCode = widget.container.fileSharingCoordinator
          .hasReceiveTicketFor(peer.deviceId);
      // Folders always go as a batch: the batch offer carries their paths.
      if (widget.documents.length > 1 ||
          viaReceiveCode ||
          _folderName != null) {
        // The transfer screen follows this peer's files one by one.
        if (mounted) {
          navigator.pop(); // Close bottom sheet
        }
        navigator.push(
          MaterialPageRoute(
            builder: (_) => TransferDetailPage(
              container: widget.container,
              peerDeviceId: peer.deviceId,
            ),
          ),
        );
        await widget.container.fileSharingCoordinator.sendFilesToPeer(
          peer: peer,
          documents: widget.documents,
        );
      } else {
        // Initiate outbound single file transfer
        final task = await widget.container.fileSharingCoordinator
            .sendFileToPeer(peer, preselectedDoc: widget.document);

        if (mounted) {
          navigator.pop(); // Close bottom sheet
        }

        if (task != null) {
          navigator.push(
            MaterialPageRoute(
              builder: (_) => TransferDetailPage(
                container: widget.container,
                transferId: task.transferId,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendingToPeerId = null;
        });
        showVayuNotice(
          null,
          messenger: messenger,
          friendlyError(e, peerName: peer.displayName),
          tone: VayuNoticeTone.problem,
        );
      }
    }
  }
}
