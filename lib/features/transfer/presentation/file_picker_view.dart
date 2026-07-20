import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/models/transfer_models.dart';
import '../providers/connection_provider.dart';
import '../providers/file_picker_provider.dart';
import '../providers/file_transfer_provider.dart';

class FilePickerView extends ConsumerWidget {
  const FilePickerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filePickerState = ref.watch(filePickerProvider);
    final filePickerNotifier = ref.read(filePickerProvider.notifier);
    final transferState = ref.watch(fileTransferProvider);
    final connectionState = ref.watch(connectionProvider);
    final transferNotifier = ref.read(fileTransferProvider.notifier);
    final canSend =
        connectionState.status == ConnectionStatus.connected &&
        connectionState.device != null &&
        filePickerState.files.isNotEmpty &&
        !transferState.items.any(
          (item) =>
              item.direction == TransferDirection.outgoing && !item.isTerminal,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: filePickerNotifier.pickFiles,
                icon: const Icon(Icons.folder_open),
                label: const Text('Select Files'),
              ),
            ),
          ],
        ),
        if (filePickerState.status == FilePickerStatus.picking)
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: CircularProgressIndicator(),
          ),
        if (connectionState.status != ConnectionStatus.connected)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Connect to a device before sending files.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (connectionState.device != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Target peer: ${connectionState.device!.name}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Transport is chosen automatically after Send. The app uses the lightest path that fits the file and the current device conditions.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        if (filePickerState.files.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            'Selected Files:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: filePickerState.files.length,
              itemBuilder: (context, index) {
                final file = filePickerState.files[index];
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file),
                  title: Text(file.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${(file.size / 1024).toStringAsFixed(2)} KB'),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.send),
                onPressed: canSend
                    ? () async {
                        final device = connectionState.device;
                        if (device == null) return;

                        try {
                          await transferNotifier.enqueueOutgoingFiles(
                            peer: device,
                            files: filePickerState.files,
                          );
                          filePickerNotifier.clearFiles();
                        } catch (error) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(error.toString())),
                          );
                        }
                      }
                    : null,
                label: const Text('Send'),
              ),
              const SizedBox(width: 16),
              TextButton(
                onPressed: filePickerNotifier.clearFiles,
                child: const Text('Clear Selection'),
              ),
            ],
          ),
          if (transferState.activeTransferId != null) ...[
            const SizedBox(height: 12),
            Text(
              'Active transfer: ${transferState.activeTransferId}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ],
    );
  }
}
