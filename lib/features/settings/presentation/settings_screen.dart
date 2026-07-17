import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/constants.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            const SliverAppBar(pinned: true, title: Text('Settings')),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate.fixed([
                  _SectionTitle('Device'),
                  const SizedBox(height: 10),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          TextField(
                            enabled: false,
                            decoration: const InputDecoration(
                              labelText: 'Device name',
                              hintText: 'SiloSend Device',
                            ),
                          ),
                          const SizedBox(height: 12),
                          ListTile(
                            enabled: false,
                            title: const Text('Auto accept transfers'),
                            subtitle: const Text(
                              'Applies to incoming requests (mock)',
                            ),
                            trailing: Switch(value: true, onChanged: null),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _SectionTitle('Preferences'),
                  const SizedBox(height: 10),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          ListTile(
                            enabled: false,
                            leading: const Icon(Icons.color_lens),
                            title: const Text('Theme'),
                            subtitle: Text(
                              'System (mock)',
                              style: theme.textTheme.bodySmall,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {},
                          ),
                          const Divider(height: 1),
                          ListTile(
                            enabled: false,
                            leading: const Icon(Icons.language),
                            title: const Text('Language'),
                            subtitle: const Text(
                              'English (mock)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {},
                          ),
                          const Divider(height: 1),
                          ListTile(
                            enabled: false,
                            leading: const Icon(Icons.sd_storage),
                            title: const Text('Storage location'),
                            subtitle: const Text(
                              'Internal storage (mock)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {},
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _SectionTitle('About'),
                  const SizedBox(height: 10),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'SiloSend',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Offline-first file sharing UI (mock).',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Privacy: no networking implemented in Phase 1.',
                            style: TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            onPressed: () => GoRouter.of(
                              context,
                            ).go(AppConstants.routeAbout),
                            icon: const Icon(Icons.info_outline),
                            label: const Text('Open About'),
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

class _SectionTitle extends StatelessWidget {
  final String label;
  const _SectionTitle(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(label, style: theme.textTheme.titleMedium);
  }
}
