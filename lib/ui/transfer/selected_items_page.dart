import 'package:flutter/material.dart';

import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/transfer/peer_selection_sheet.dart';

/// Review of what Android's picker returned, before choosing a device:
/// count, total size, and a way to drop items. Next opens the device
/// screen. Part of the send flow, which closes as a whole when the
/// transfer starts.
class SelectedItemsPage extends StatefulWidget {
  final List<SelectedDocument> documents;
  final AppContainer container;

  /// Name of the picked folder, when a folder is sent.
  final String? folderName;

  /// See [PeerSelectionSheet.receiverCode].
  final String? receiverCode;

  const SelectedItemsPage({
    super.key,
    required this.documents,
    required this.container,
    this.folderName,
    this.receiverCode,
  });

  static Future<void> open(
    BuildContext context, {
    required List<SelectedDocument> documents,
    required AppContainer container,
    String? folderName,
    String? receiverCode,
  }) {
    if (documents.isEmpty) return Future.value();
    return Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: sendFlowRouteName),
        builder: (_) => SelectedItemsPage(
          documents: documents,
          container: container,
          folderName: folderName,
          receiverCode: receiverCode,
        ),
      ),
    );
  }

  @override
  State<SelectedItemsPage> createState() => _SelectedItemsPageState();
}

class _SelectedItemsPageState extends State<SelectedItemsPage> {
  late final List<SelectedDocument> _docs = List.of(widget.documents);

  int get _totalBytes =>
      _docs.fold(0, (sum, d) => sum + (d.sizeBytes > 0 ? d.sizeBytes : 0));

  void _remove(SelectedDocument doc) {
    setState(() => _docs.remove(doc));
    // Nothing left to send: back to where Send was started.
    if (_docs.isEmpty) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder = widget.folderName;
    final count = _docs.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(folder != null ? 'Send a folder' : 'Selected files'),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: _docs.isEmpty
                ? null
                : () => PeerSelectionSheet.show(
                    context,
                    documents: List.of(_docs),
                    container: widget.container,
                    receiverCode: widget.receiverCode,
                  ),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Next: choose device'),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  Icon(
                    folder != null
                        ? Icons.folder_rounded
                        : Icons.collections_bookmark_outlined,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      folder != null
                          ? '$folder · $count ${count == 1 ? 'file' : 'files'}'
                          : '$count ${count == 1 ? 'item' : 'items'} selected',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    formatBytes(_totalBytes),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // As tall as the list, scrolling once it fills the screen.
            Flexible(
              child: Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _docs.length,
                  separatorBuilder: (_, _) =>
                      const Divider(indent: 72, endIndent: 16),
                  itemBuilder: (context, i) {
                    final doc = _docs[i];
                    return ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          fileIconFor(doc.name, doc.mimeType),
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      title: Text(
                        doc.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (doc.sizeBytes >= 0) formatBytes(doc.sizeBytes),
                          if (doc.folder != null && doc.folder!.isNotEmpty)
                            doc.folder!,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove ${doc.name}',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => _remove(doc),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Icon for a file by its type (shared by the send screens).
IconData fileIconFor(String name, String? mimeType) {
  final mime = mimeType ?? '';
  final lower = name.toLowerCase();
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime.startsWith('audio/')) return Icons.audio_file_outlined;
  if (mime == 'application/pdf' || lower.endsWith('.pdf')) {
    return Icons.picture_as_pdf_outlined;
  }
  if (lower.endsWith('.apk')) return Icons.android_rounded;
  if (lower.endsWith('.zip') ||
      lower.endsWith('.rar') ||
      lower.endsWith('.7z') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.gz')) {
    return Icons.folder_zip_outlined;
  }
  return Icons.insert_drive_file_outlined;
}
