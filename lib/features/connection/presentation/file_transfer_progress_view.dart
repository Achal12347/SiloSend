import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/features/connection/providers/file_picker_provider.dart';
import 'package:silosend/features/connection/providers/file_transfer_provider.dart';

class FileTransferProgressView extends ConsumerWidget {
  const FileTransferProgressView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transferState = ref.watch(fileTransferProvider);

    if (transferState.status == FileTransferStatus.initial) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (transferState.status == FileTransferStatus.sending) ...[
              Text(
                'Sending: ${transferState.currentFile ?? ''}',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: transferState.progress),
              const SizedBox(height: 8),
              Text('${(transferState.progress * 100).toStringAsFixed(0)}%'),
            ],
            if (transferState.status == FileTransferStatus.sent) ...[
              const Icon(Icons.check_circle, color: Colors.green, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Files sent successfully!',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  ref.read(fileTransferProvider.notifier).reset();
                  ref.read(filePickerProvider.notifier).clearFiles();
                },
                child: const Text('Done'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
