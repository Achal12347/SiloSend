import 'package:flutter/material.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final mockTransfers = <_HistoryItem>[
      const _HistoryItem(
        fileName: 'ProjectBrief.docx',
        peerName: 'Ava’s Phone',
        direction: _HistoryDirection.sent,
        status: 'Completed',
        when: 'Yesterday',
      ),
      const _HistoryItem(
        fileName: 'Invoice_0421.pdf',
        peerName: 'Mi Note',
        direction: _HistoryDirection.received,
        status: 'Completed',
        when: '2 days ago',
      ),
      const _HistoryItem(
        fileName: 'Vacation_2025.zip',
        peerName: 'Sam’s Tablet',
        direction: _HistoryDirection.sent,
        status: 'In progress',
        when: 'Today',
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverAppBar(pinned: true, title: Text('History')),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  TextField(
                    enabled: false,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'Search transfers (mock)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const [
                      _FilterChip(label: 'All', selected: true),
                      _FilterChip(label: 'Sent', selected: false),
                      _FilterChip(label: 'Received', selected: false),
                    ],
                  ),
                  const SizedBox(height: 16),
                  for (final item in mockTransfers) ...[
                    _HistoryTile(item: item),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 24),
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                child: Text(
                  'Phase 1: History is UI-only with mock data.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryItem {
  final String fileName;
  final String peerName;
  final _HistoryDirection direction;
  final String status;
  final String when;

  const _HistoryItem({
    required this.fileName,
    required this.peerName,
    required this.direction,
    required this.status,
    required this.when,
  });
}

enum _HistoryDirection { sent, received }

class _HistoryTile extends StatelessWidget {
  final _HistoryItem item;

  const _HistoryTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconData = item.direction == _HistoryDirection.sent
        ? Icons.upload
        : Icons.download;
    final directionLabel = item.direction == _HistoryDirection.sent
        ? 'Sent'
        : 'Received';

    return Card(
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(iconData, color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(
          item.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('$directionLabel • ${item.peerName} • ${item.when}'),
        trailing: IconButton(
          tooltip: 'Delete (mock)',
          icon: const Icon(Icons.delete_outline),
          onPressed: null,
        ),
        onTap: () {
          // Phase 1 UI-only.
        },
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;

  const _FilterChip({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {},
      selectedColor: theme.colorScheme.primaryContainer,
    );
  }
}
