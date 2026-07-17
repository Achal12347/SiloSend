import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/features/connection/providers/file_picker_provider.dart';
import 'package:silosend/features/connection/providers/file_transfer_provider.dart';

class FilePickerView extends ConsumerWidget {
  const FilePickerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filePickerState = ref.watch(filePickerProvider);
    final filePickerNotifier = ref.read(filePickerProvider.notifier);
    final transferState = ref.watch(fileTransferProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton.icon(
          onPressed: filePickerNotifier.pickFiles,
          icon: const Icon(Icons.folder_open),
          label: const Text('Select Files'),
        ),
        if (filePickerState.status == FilePickerStatus.picking)
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: CircularProgressIndicator(),
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
                onPressed: (transferState.status == FileTransferStatus.sending)
                    ? null
                    : () => ref
                          .read(fileTransferProvider.notifier)
                          .sendFiles(filePickerState.files),
                label: const Text('Send'),
              ),
              const SizedBox(width: 16),
              TextButton(
                onPressed: filePickerNotifier.clearFiles,
                child: const Text('Clear Selection'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
