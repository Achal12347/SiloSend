import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';

/// Modal dialog displaying local pairing parameters and direct out-of-band connection controls.
class PairingDialog extends StatefulWidget {
  final AppContainer container;

  const PairingDialog({super.key, required this.container});

  /// Displays the pairing dialog.
  static Future<void> show(BuildContext context, AppContainer container) {
    return showDialog(
      context: context,
      builder: (ctx) => PairingDialog(container: container),
    );
  }

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  final TextEditingController _uriController = TextEditingController();
  bool _isConnecting = false;
  String? _errorMessage;
  bool? _nfcAvailable;
  bool? _nfcEnabled;

  @override
  void initState() {
    super.initState();
    _checkNfcStatus();
  }

  @override
  void dispose() {
    _uriController.dispose();
    super.dispose();
  }

  Future<void> _checkNfcStatus() async {
    final nfc = widget.container.nfcPairingService;
    final available = await nfc.isNfcAvailable;
    final enabled = available ? await nfc.isNfcEnabled : false;
    if (mounted) {
      setState(() {
        _nfcAvailable = available;
        _nfcEnabled = enabled;
      });
    }
  }

  PairingPayload _buildLocalPayload() {
    final identity = widget.container.identity;
    final lanPort = widget.container.lanServer?.boundPort ?? 53531;

    return PairingPayload(
      deviceIdHex: identity?.idHex ?? '0' * 32,
      displayName: identity?.displayName ?? '${AppConstants.appName}-Device',
      supportedTransports: {
        TransportType.lan,
        if (widget.container.capabilities.supportsBle) TransportType.ble,
      },
      lanPort: lanPort,
      pairingToken: 'token_${identity?.idHex.substring(0, 8) ?? '00000000'}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _handleConnect() async {
    final input = _uriController.text.trim();
    if (input.isEmpty) return;

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      if (input.startsWith('vayu://pair') || input.startsWith('silosend://pair')) {
        final payload = PairingPayload.fromUri(Uri.parse(input));
        if (payload.lanPort != null && payload.lanAddress != null) {
          await widget.container.connectionManager.connectToLanPeer(
            remoteAddress: payload.lanAddress!,
            remotePort: payload.lanPort!,
            targetDeviceId: payload.deviceIdHex,
          );
        } else {
          throw const FormatException(
            'Pairing URI missing IP address or port for direct connection',
          );
        }
      } else if (input.contains(':')) {
        // Direct IP:Port format
        final parts = input.split(':');
        final host = parts[0];
        final port = int.tryParse(parts[1]) ?? 53531;

        await widget.container.connectionManager.connectToLanPeer(
          remoteAddress: host,
          remotePort: port,
        );
      } else {
        throw const FormatException(
          'Please enter a valid vayu://pair URI or IP:Port (e.g. 192.168.1.50:53531)',
        );
      }

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Out-of-band connection established!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payload = _buildLocalPayload();
    final uriString = payload.toUri().toString();

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.qr_code_2_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          const Text('Out-of-Band Pairing'),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Direct connection parameters for offline negotiation without ambient discovery beacons:',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),

              // Local Pairing URI Box
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Local Pairing URI',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          tooltip: 'Copy URI',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: uriString));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Pairing URI copied to clipboard',
                                ),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      uriString,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Local Parameters Overview
              _buildDetailRow(theme, 'Device', payload.displayName),
              _buildDetailRow(
                theme,
                'Device ID',
                '${payload.deviceIdHex.substring(0, 8)}...${payload.deviceIdHex.substring(28)}',
              ),
              _buildDetailRow(theme, 'LAN Port', '${payload.lanPort ?? 53531}'),
              const Divider(height: 24),

              // NFC Capabilities Status
              Row(
                children: [
                  Icon(
                    Icons.nfc_rounded,
                    size: 18,
                    color: _nfcAvailable == true
                        ? (_nfcEnabled == true ? Colors.green : Colors.orange)
                        : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _nfcAvailable == null
                          ? 'Checking NFC status...'
                          : (_nfcAvailable!
                                ? (_nfcEnabled!
                                      ? 'NFC Ready (Tap to exchange)'
                                      : 'NFC Disabled in System Settings')
                                : 'NFC Unsupported on this Device'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: _nfcAvailable == true && _nfcEnabled == true
                            ? Colors.green.shade700
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),

              // Connect to Remote Peer Box
              Text(
                'Connect to Remote Peer Directly',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _uriController,
                decoration: InputDecoration(
                  hintText: 'Paste vayu://pair URI or IP:Port',
                  hintStyle: const TextStyle(fontSize: 12),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  errorText: _errorMessage,
                ),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _isConnecting ? null : _handleConnect,
                icon: _isConnecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.link_rounded, size: 18),
                label: Text(
                  _isConnecting ? 'Connecting...' : 'Connect Out-of-Band',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildDetailRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
