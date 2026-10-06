import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/file_picker_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/state/app_container.dart';
import 'package:silosend_datasharing_app/domain/security/trust_level.dart';

/// Modal bottom sheet allowing the user to select a discovered nearby SiloSend
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
           documents ?? (document != null ? [document] : const <SelectedDocument>[]);

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
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _isSending = false;
  String? _sendingToPeerId;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    final isTesting = Platform.environment.containsKey('FLUTTER_TEST') ||
        WidgetsBinding.instance.runtimeType.toString().contains('Test');
    if (!isTesting) {
      _pulseController.repeat(reverse: true);
    } else {
      _pulseController.value = 1.0;
    }

    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Ensure discovery is actively running when picker sheet is open
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final raw = widget.container.capabilityCoordinator.rawCapabilities;
        if (raw.isNearbyPermissionNotRequested) {
          await widget.container.capabilityCoordinator.requestNearbyAccess();
        }
        if (widget.container.discoveryStatus == DiscoveryStatus.idle) {
          await widget.container.startDiscoveryAndAdvertising();
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = widget.document;
    final isBatch = widget.documents.length > 1;
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
                        isBatch
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
                'Send To Nearby Device',
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
                          'Searching...',
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
        ],
      ),
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
            'Looking for nearby SiloSend devices...',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Keep both devices close and ensure SiloSend is open on the other device.',
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
                          color: Colors.green.shade700,
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
      if (widget.documents.length > 1) {
        if (mounted) {
          navigator.pop(); // Close bottom sheet
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Sending ${widget.documents.length} files to ${peer.displayName}...',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
        await widget.container.fileSharingCoordinator.sendFilesToPeer(
          peer: peer,
          documents: widget.documents,
        );
      } else {
        // Initiate outbound single file transfer
        final task = await widget.container.fileSharingCoordinator.sendFileToPeer(
          peer,
          preselectedDoc: widget.document,
        );

        if (mounted) {
          navigator.pop(); // Close bottom sheet
        }

        if (task != null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Sending "${widget.document.name}" to ${peer.displayName}...',
              ),
              duration: const Duration(seconds: 3),
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
        messenger.showSnackBar(
          SnackBar(
            content: Text('Send failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }
}
