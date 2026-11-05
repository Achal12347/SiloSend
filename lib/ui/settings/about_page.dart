import 'package:flutter/material.dart';

import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_mark.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// The app, its version, who makes it and where to find the project.
class AboutPage extends StatelessWidget {
  final AppContainer container;

  const AboutPage({super.key, required this.container});

  static Future<void> open(BuildContext context, AppContainer container) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AboutPage(container: container)),
      );

  Future<void> _openLink(BuildContext context, String url) async {
    final opened = await container.platformService.openUri(Uri.parse(url));
    if (!opened && context.mounted) {
      showVayuNotice(
        context,
        "Couldn't open the link",
        tone: VayuNoticeTone.problem,
      );
    }
  }

  /// The address without `https://`, as people read it.
  static String _shortUrl(String url) => url.replaceFirst('https://', '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            const Center(child: VayuMark(size: 88)),
            const SizedBox(height: 16),
            Text(
              AppConstants.appName,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 2),
            Text(
              'by ${AppConstants.brandName}',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Version ${AppConstants.appVersionLabel}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: 'Developer'),
            Card(
              child: Column(
                children: [
                  const ListTile(
                    leading: Icon(Icons.person_outline_rounded),
                    title: Text(AppConstants.developerName),
                  ),
                  const Divider(height: 1),
                  _LinkTile(
                    icon: Icons.account_circle_outlined,
                    title: 'GitHub profile',
                    address: _shortUrl(AppConstants.developerGitHubUrl),
                    onTap: () =>
                        _openLink(context, AppConstants.developerGitHubUrl),
                  ),
                  const Divider(height: 1),
                  _LinkTile(
                    icon: Icons.code_rounded,
                    title: 'Source code',
                    address: _shortUrl(AppConstants.sourceCodeUrl),
                    onTap: () => _openLink(context, AppConstants.sourceCodeUrl),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'Legal'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Open-source licences'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: AppConstants.appName,
                  applicationVersion: AppConstants.appVersionLabel,
                  applicationLegalese: '© ${AppConstants.brandName}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String address;
  final VoidCallback onTap;

  const _LinkTile({
    required this.icon,
    required this.title,
    required this.address,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(address),
    trailing: const Icon(Icons.open_in_new_rounded, size: 20),
    onTap: onTap,
  );
}
