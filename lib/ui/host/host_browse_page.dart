import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/host/host_service.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_batch.dart';
import 'package:vayu/domain/host/host_payloads.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/friendly_error.dart';
import 'package:vayu/ui/transfer/selected_items_page.dart' show fileIconFor;
import 'package:vayu/ui/transfer/transfer_detail_page.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// What one host shares: choose items and download them. The files arrive
/// as an ordinary transfer, accepted because this phone asked for them.
class HostBrowsePage extends StatefulWidget {
  final AppContainer container;
  final DiscoveredPeer host;

  const HostBrowsePage({
    super.key,
    required this.container,
    required this.host,
  });

  static Future<void> open(
    BuildContext context,
    AppContainer container, {
    required DiscoveredPeer host,
  }) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => HostBrowsePage(container: container, host: host),
    ),
  );

  @override
  State<HostBrowsePage> createState() => _HostBrowsePageState();
}

class _HostBrowsePageState extends State<HostBrowsePage> {
  HostCatalog? _catalog;
  Object? _error;
  final Set<String> _selected = {};
  bool _requesting = false;
  StreamSubscription<String>? _endedSub;
  StreamSubscription<TransferBatch>? _batchSub;

  HostService get _service => widget.container.hostService;
  String get _hostName => widget.host.displayName;

  @override
  void initState() {
    super.initState();
    widget.container.fileSharingCoordinator.rememberPeer(widget.host);
    _endedSub = _service.hostsEnded.listen((hostId) {
      if (hostId.toLowerCase() != widget.host.deviceId.toLowerCase()) return;
      if (!mounted) return;
      showVayuNotice(context, '$_hostName stopped hosting.');
      setState(() => _catalog = null);
      _load();
    });
    _batchSub = widget.container.fileSharingCoordinator.hostBatches.listen((b) {
      if (!mounted) return;
      if (b.peerDeviceId.toLowerCase() != widget.host.deviceId.toLowerCase()) {
        return;
      }
      TransferDetailPage.open(context, widget.container, batchId: b.batchId);
    });
    _load();
  }

  @override
  void dispose() {
    _endedSub?.cancel();
    _batchSub?.cancel();
    super.dispose();
  }

  bool _checkingPin = false;

  Future<void> _load({String? pin}) async {
    setState(() {
      _error = null;
      _checkingPin = pin != null;
    });
    try {
      final catalog = await _service.browse(widget.host.deviceId, pin: pin);
      if (mounted) {
        setState(() {
          _catalog = catalog;
          _selected.removeWhere(
            (id) => !catalog.items.any((i) => i.itemId == id),
          );
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _checkingPin = false);
    }
  }

  Future<void> _download() async {
    if (_selected.isEmpty || _requesting) return;
    setState(() => _requesting = true);
    try {
      final answer = await _service.download(
        widget.host.deviceId,
        _selected.toList(),
      );
      if (!mounted) return;
      if (!answer.accepted) {
        showVayuNotice(context, switch (answer.reason) {
          HostDeclineReason.notHosting => '$_hostName stopped hosting.',
          HostDeclineReason.unknownItems =>
            'Those files are no longer shared. The list is refreshed.',
          HostDeclineReason.pinRequired =>
            '$_hostName asks for the PIN again (it may have changed).',
          _ => '$_hostName could not send now. Try again.',
        }, tone: VayuNoticeTone.problem);
        _load();
        return;
      }
      showVayuNotice(
        context,
        answer.queued
            ? '$_hostName is sending to others. Your files follow next.'
            : 'Downloading ${_selected.length} ${_selected.length == 1 ? 'file' : 'files'} from $_hostName',
        tone: VayuNoticeTone.success,
      );
      setState(_selected.clear);
    } catch (e) {
      if (mounted) {
        showVayuNotice(
          context,
          e is HostUnavailableException ? e.message : friendlyError(e),
          tone: VayuNoticeTone.problem,
        );
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = _catalog;
    final items = catalog?.items ?? const <HostedItem>[];
    final selectedBytes = items
        .where((i) => _selected.contains(i.itemId))
        .fold<int>(0, (sum, i) => sum + i.sizeBytes);

    final Widget body;
    if (_error != null) {
      body = _Message(
        icon: Icons.wifi_off_rounded,
        text: _error is HostUnavailableException
            ? (_error as HostUnavailableException).message
            : "Couldn't reach $_hostName. Move closer and try again.",
        action: FilledButton(onPressed: _load, child: const Text('Try again')),
      );
    } else if (catalog == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!catalog.hosting) {
      body = _Message(
        icon: Icons.cell_tower_rounded,
        text: '$_hostName is not hosting anything right now.',
        action: OutlinedButton(onPressed: _load, child: const Text('Refresh')),
      );
    } else if (catalog.lock case final lock?) {
      body = _PinEntry(
        hostName: _hostName,
        shareName: catalog.shareName,
        lock: lock,
        attemptsLeft: catalog.attemptsLeft,
        checking: _checkingPin,
        onSubmit: (pin) => _load(pin: pin),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Row(
              children: [
                Icon(
                  catalog.access == HostAccess.private
                      ? Icons.lock_outline_rounded
                      : Icons.public_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${catalog.shareName} · ${items.length} '
                    '${items.length == 1 ? 'file' : 'files'} · '
                    '${formatBytes(catalog.totalBytes)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == items.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(items.map((i) => i.itemId));
                    }
                  }),
                  child: Text(
                    _selected.length == items.length
                        ? 'Select none'
                        : 'Select all',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const Divider(indent: 72, endIndent: 16),
                    CheckboxListTile(
                      value: _selected.contains(items[i].itemId),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(items[i].itemId);
                        } else {
                          _selected.remove(items[i].itemId);
                        }
                      }),
                      secondary: Icon(
                        fileIconFor(items[i].name, items[i].mimeType),
                      ),
                      title: Text(
                        items[i].name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          formatBytes(items[i].sizeBytes),
                          if (items[i].folder case final f?)
                            if (f.isNotEmpty) f,
                        ].join(' · '),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(_hostName)),
      bottomNavigationBar: catalog?.hosting == true && !catalog!.isLocked
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed: _selected.isEmpty || _requesting
                      ? null
                      : _download,
                  icon: _requesting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded),
                  label: Text(
                    _selected.isEmpty
                        ? 'Choose files to download'
                        : 'Download ${_selected.length} · ${formatBytes(selectedBytes)}',
                  ),
                ),
              ),
            )
          : null,
      body: SafeArea(child: body),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget action;

  const _Message({
    required this.icon,
    required this.text,
    required this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            action,
          ],
        ),
      ),
    );
  }
}

/// A private share: the PIN shown on the host's phone, entered here.
class _PinEntry extends StatefulWidget {
  final String hostName;
  final String shareName;
  final HostLock lock;
  final int? attemptsLeft;
  final bool checking;
  final ValueChanged<String> onSubmit;

  const _PinEntry({
    required this.hostName,
    required this.shareName,
    required this.lock,
    required this.attemptsLeft,
    required this.checking,
    required this.onSubmit,
  });

  @override
  State<_PinEntry> createState() => _PinEntryState();
}

class _PinEntryState extends State<_PinEntry> {
  final _controller = TextEditingController();

  @override
  void didUpdateWidget(covariant _PinEntry old) {
    super.didUpdateWidget(old);
    // A wrong PIN clears the field for the next try.
    if (widget.lock != old.lock || widget.attemptsLeft != old.attemptsLeft) {
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _controller.text;
    if (hostPinFormat.hasMatch(pin) && !widget.checking) widget.onSubmit(pin);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = widget.lock == HostLock.tooManyAttempts;
    final left = widget.attemptsLeft;
    final problem = switch (widget.lock) {
      HostLock.pinRequired => null,
      HostLock.pinWrong =>
        'That PIN is not right.'
            '${left != null ? ' $left ${left == 1 ? 'try' : 'tries'} left.' : ''}',
      HostLock.tooManyAttempts =>
        'Too many wrong PINs. ${widget.hostName} has to host again before '
            'this phone can try once more.',
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 40,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          widget.shareName.isEmpty ? 'Private share' : widget.shareName,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          'Private · enter the 6-digit PIN shown on ${widget.hostName}\'s '
          'phone.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _controller,
          enabled: !blocked && !widget.checking,
          autofocus: !blocked,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 8),
          decoration: InputDecoration(
            counterText: '',
            hintText: '••••••',
            errorText: problem,
            errorMaxLines: 3,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed:
              blocked ||
                  widget.checking ||
                  !hostPinFormat.hasMatch(_controller.text)
              ? null
              : _submit,
          child: widget.checking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Open share'),
        ),
      ],
    );
  }
}
