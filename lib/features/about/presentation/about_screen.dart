import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverAppBar(pinned: true, title: Text('About')),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate.fixed([
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'SiloSend',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Offline-first file sharing (UI mock, Phase 1).',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Text('Privacy', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 6),
                          Text(
                            'In Phase 1, there is no BLE/WiFi/file transfer logic implemented.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Roadmap', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 10),
                          _RoadmapItem(step: 'Phase 2', label: 'Discovery'),
                          _RoadmapItem(step: 'Phase 3', label: 'Connection'),
                          _RoadmapItem(
                            step: 'Phase 4',
                            label: 'File Transfer Engine',
                          ),
                          _RoadmapItem(step: 'Phase 6', label: 'Security'),
                          _RoadmapItem(step: 'Phase 7', label: 'Offline Chat'),
                          _RoadmapItem(
                            step: 'Phase 8',
                            label: 'History Persistence',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoadmapItem extends StatelessWidget {
  final String step;
  final String label;

  const _RoadmapItem({required this.step, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              step,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
