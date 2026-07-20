import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/models/device.dart';
import '../providers/connection_provider.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  final Device device;

  const ConnectionScreen({super.key, required this.device});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(connectionProvider.notifier).setDevice(widget.device);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(connectionProvider);
    final connectionNotifier = ref.read(connectionProvider.notifier);

    final statusLabel = switch (connectionState.status) {
      ConnectionStatus.initial => 'Ready to connect',
      ConnectionStatus.validating => 'Validating device',
      ConnectionStatus.connecting => 'Connecting',
      ConnectionStatus.connected => 'Connected',
      ConnectionStatus.disconnecting => 'Disconnecting',
      ConnectionStatus.disconnected => 'Disconnected',
      ConnectionStatus.error => 'Connection error',
    };

    final showPrimaryActions =
        connectionState.status == ConnectionStatus.initial ||
        connectionState.status == ConnectionStatus.disconnected ||
        connectionState.status == ConnectionStatus.error;

    return Scaffold(
      appBar: AppBar(title: Text(widget.device.name)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Icon(
                          connectionState.status == ConnectionStatus.connected
                              ? Icons.link
                              : Icons.link_off,
                          size: 44,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          statusLabel,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${widget.device.name} - ${widget.device.id}',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                        if (connectionState.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            connectionState.errorMessage!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (connectionState.status == ConnectionStatus.validating ||
                    connectionState.status == ConnectionStatus.connecting ||
                    connectionState.status == ConnectionStatus.disconnecting)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 20),
                    child: CircularProgressIndicator(),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    if (showPrimaryActions)
                      ElevatedButton(
                        onPressed: connectionNotifier.connect,
                        child: const Text('Connect'),
                      ),
                    if (showPrimaryActions)
                      OutlinedButton(
                        onPressed: connectionNotifier.reconnect,
                        child: const Text('Reconnect'),
                      ),
                    if (connectionState.status == ConnectionStatus.connected)
                      OutlinedButton.icon(
                        onPressed: connectionNotifier.disconnect,
                        icon: const Icon(Icons.link_off),
                        label: const Text('Disconnect'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
