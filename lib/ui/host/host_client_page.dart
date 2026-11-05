import 'package:flutter/material.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/host/host_service.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/state/app_scope.dart';
import 'package:vayu/domain/host/host_payloads.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/host/host_browse_page.dart';
import 'package:vayu/ui/shell/primary_actions.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';

/// Host & Client tab.
///
/// Host: share a set of files so nearby phones can browse and download
/// them; see who is connected and what each is doing. Client: phones that
/// host nearby (they announce it in their beacon), opened to browse.
class HostClientPage extends StatefulWidget {
  const HostClientPage({super.key});

  @override
  State<HostClientPage> createState() => _HostClientPageState();
}

class _HostClientPageState extends State<HostClientPage> {
  bool _host = true;

  @override
  Widget build(BuildContext context) {
    final container = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('Host & Client'),
        actions: primaryAppBarActions(context, container),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Host'),
                  icon: Icon(Icons.cell_tower_rounded),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Client'),
                  icon: Icon(Icons.devices_rounded),
                ),
              ],
              selected: {_host},
              onSelectionChanged: (v) => setState(() => _host = v.first),
            ),
            const SizedBox(height: 16),
            if (_host)
              _HostView(container: container)
            else
              _ClientView(container: container),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ host

class _HostView extends StatefulWidget {
  final AppContainer container;

  const _HostView({required this.container});

  @override
  State<_HostView> createState() => _HostViewState();
}

class _HostViewState extends State<_HostView> {
  /// Chosen before the files: who may open the share.
  HostAccess _access = HostAccess.public;

  AppContainer get container => widget.container;
  HostService get _host => container.hostService;

  Future<void> _start(BuildContext context, {required bool folder}) async {
    try {
      final List<SelectedDocument> docs;
      String name;
      if (folder) {
        final picked = await container.filePickerService.pickFolder();
        if (picked == null) return;
        docs = picked.documents;
        name = picked.name;
      } else {
        docs = await container.filePickerService.pickMultipleDocuments();
        name = "${container.identity?.displayName ?? 'My'} files";
      }
      if (docs.isEmpty) {
        if (context.mounted) {
          showVayuNotice(context, 'Nothing to share there.');
        }
        return;
      }
      _host.startHosting(name, docs, access: _access);
    } catch (_) {
      if (context.mounted) {
        showVayuNotice(
          context,
          "Couldn't open your files. Please try again.",
          tone: VayuNoticeTone.problem,
        );
      }
    }
  }

  Future<void> _stop(BuildContext context) async {
    final ok = await showVayuConfirm(
      context,
      title: 'Stop hosting?',
      message: 'Downloads in progress will finish.',
      confirmLabel: 'Stop hosting',
      destructive: true,
    );
    if (ok) await _host.stopHosting();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return StreamBuilder<void>(
      stream: _host.changes,
      builder: (context, _) {
        if (!_host.isHosting) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.cell_tower_rounded,
                    size: 36,
                    color: palette.accent,
                  ),
                  const SizedBox(height: 12),
                  Text('Start hosting', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  Text('Who can open it', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  _AccessChoice(
                    icon: Icons.public_rounded,
                    title: 'Open to all',
                    subtitle: 'Any nearby phone can download',
                    selected: _access == HostAccess.public,
                    onTap: () => setState(() => _access = HostAccess.public),
                  ),
                  const SizedBox(height: 8),
                  _AccessChoice(
                    icon: Icons.lock_outline_rounded,
                    title: 'Private (PIN)',
                    subtitle: 'Only phones with the PIN',
                    selected: _access == HostAccess.private,
                    onTap: () => setState(() => _access = HostAccess.private),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _start(context, folder: false),
                    icon: const Icon(Icons.insert_drive_file_outlined),
                    label: const Text('Host files'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _start(context, folder: true),
                    icon: const Icon(Icons.folder_outlined),
                    label: const Text('Host a folder'),
                  ),
                ],
              ),
            ),
          );
        }
        final clients = _host.clients;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Visible only while this phone really advertises.
                    StreamBuilder<DiscoveryStatus>(
                      stream: container.discoveryStatusStream,
                      initialData: container.discoveryStatus,
                      builder: (context, status) {
                        final visible =
                            (status.data ?? DiscoveryStatus.idle).isActive;
                        return StatusPill(
                          label: visible ? 'Hosting · visible nearby' : 'Hosting · not visible: turn on Wi-Fi or Bluetooth',
                          icon: Icons.circle,
                          foreground: visible
                              ? palette.success
                              : palette.warning,
                          background: visible
                              ? palette.successContainer
                              : palette.warningContainer,
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    StatusPill(
                      label: _host.access == HostAccess.private
                          ? 'Private · PIN needed'
                          : 'Open to all',
                      icon: _host.access == HostAccess.private
                          ? Icons.lock_outline_rounded
                          : Icons.public_rounded,
                      foreground: palette.accent,
                      background: palette.accentContainer,
                    ),
                    const SizedBox(height: 12),
                    Text(_host.shareName, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      '${_host.itemCount} ${_host.itemCount == 1 ? 'file' : 'files'} · '
                      '${formatBytes(_host.totalBytes)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_host.pin case final pin?) ...[
                      const SizedBox(height: 16),
                      _PinPanel(pin: pin),
                    ],
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: palette.danger,
                        side: BorderSide(color: palette.dangerContainer),
                      ),
                      onPressed: () => _stop(context),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Stop hosting'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SectionHeader(title: 'Connected phones (${clients.length})'),
            Card(
              child: clients.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'Phones that open your share appear here.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < clients.length; i++) ...[
                          if (i > 0) const Divider(indent: 72, endIndent: 16),
                          _ClientRow(
                            client: clients[i],
                            connected:
                                container.secureSessionManager
                                    .getSessionForPeer(clients[i].deviceId) !=
                                null,
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _ClientRow extends StatelessWidget {
  final HostClient client;
  final bool connected;

  const _ClientRow({required this.client, required this.connected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = client.filesRequested;
    final count = '$files ${files == 1 ? 'file' : 'files'}';
    final state = switch (client.state) {
      HostClientState.waitingForPin => 'Asked to enter the PIN',
      HostClientState.wrongPin => 'Entered a wrong PIN',
      HostClientState.blocked => 'Blocked: too many wrong PINs',
      HostClientState.browsing => 'Browsing your files',
      HostClientState.queued => 'Waiting in line · $count',
      HostClientState.downloading => 'Receiving $count',
      HostClientState.done => 'Received $count',
      HostClientState.failed => 'Did not receive the files',
    };
    return ListTile(
      leading: DeviceAvatar(name: client.name, seed: client.deviceId),
      title: Text(client.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$state · ${connected ? 'connected' : 'left'}'),
      trailing: client.state == HostClientState.downloading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      titleTextStyle: theme.textTheme.titleSmall,
    );
  }
}

// ---------------------------------------------------------------- client

class _ClientView extends StatelessWidget {
  final AppContainer container;

  const _ClientView({required this.container});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<DiscoveredPeer>>(
      stream: container.discoveredPeersStream,
      initialData: container.discoveredPeers,
      builder: (context, snapshot) {
        final hosts = (snapshot.data ?? const <DiscoveredPeer>[])
            .where((p) => p.isHosting)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(title: 'Hosts nearby (${hosts.length})'),
            Card(
              child: hosts.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'No phone is hosting nearby.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < hosts.length; i++) ...[
                          if (i > 0) const Divider(indent: 72, endIndent: 16),
                          ListTile(
                            leading: DeviceAvatar(
                              name: hosts[i].displayName,
                              seed: hosts[i].deviceId,
                            ),
                            title: Text(hosts[i].displayName),
                            subtitle: Row(
                              children: [
                                Icon(
                                  hosts[i].isHostingPrivate
                                      ? Icons.lock_outline_rounded
                                      : Icons.public_rounded,
                                  size: 16,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    hosts[i].isHostingPrivate
                                        ? 'Private · PIN needed'
                                        : 'Public · open to all',
                                  ),
                                ),
                              ],
                            ),
                            trailing: FilledButton(
                              onPressed: () => HostBrowsePage.open(
                                context,
                                container,
                                host: hosts[i],
                              ),
                              child: const Text('Browse'),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// One of the two hosting modes, chosen before the files.
class _AccessChoice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _AccessChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? palette.accentContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? palette.accent : theme.colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(icon, color: selected ? palette.accent : null),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? palette.accent : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The PIN of a private share, large enough to read out or show.
class _PinPanel extends StatelessWidget {
  final String pin;

  const _PinPanel({required this.pin});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.accentContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text('PIN for your share', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Semantics(
            label: 'PIN ${pin.split('').join(' ')}',
            excludeSemantics: true,
            child: Text(
              '${pin.substring(0, 3)} ${pin.substring(3)}',
              style: theme.textTheme.displaySmall?.copyWith(letterSpacing: 4),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Share it only with people you trust.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
