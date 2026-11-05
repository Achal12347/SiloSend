import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/state/app_container.dart';
import 'package:vayu/core/transfer/transfer_batch.dart';
import 'package:vayu/core/transfer/transfer_stats.dart';
import 'package:vayu/core/transfer/transfer_task_impl.dart';
import 'package:vayu/domain/contacts/contact_card.dart';
import 'package:vayu/domain/models/transfer_models.dart';
import 'package:vayu/domain/transfer/payload_destination.dart';
import 'package:vayu/ui/widgets/motion.dart';
import 'package:vayu/ui/format.dart';
import 'package:vayu/ui/theme/vayu_theme.dart';
import 'package:vayu/ui/widgets/vayu_widgets.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';
import 'package:vayu/ui/widgets/connection_attempt_card.dart';
import 'package:vayu/ui/friendly_error.dart';

/// Latest known progress for [task], also after the stream has closed.
TransferProgress? latestProgressOf(TransferTask task) {
  if (task is OutboundTransferTask) return task.lastProgress;
  if (task is InboundTransferTask) return task.lastProgress;
  return null;
}

bool _isActive(TransferStatus s) =>
    s == TransferStatus.idle ||
    s == TransferStatus.queued ||
    s == TransferStatus.connecting ||
    s == TransferStatus.transferring ||
    s == TransferStatus.paused ||
    s == TransferStatus.verifying;

String _durationLabel(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  if (minutes < 60) return '${minutes}m ${remainder}s';
  return '${minutes ~/ 60}h ${minutes % 60}m';
}

/// Full-screen sending / receiving / completion view (UI5, UI6, UI7, UI8).
///
/// Follows one transfer by [transferId], a whole batch by [batchId], or the
/// newest outgoing batch to [peerDeviceId] (started after this page opened),
/// advancing file by file. Every number comes from the transfer engine;
/// success is shown only after the receiver's SHA-256 verification.
class TransferDetailPage extends StatefulWidget {
  final AppContainer container;
  final String? transferId;
  final String? peerDeviceId;
  final String? batchId;

  /// The task itself when the caller already holds it; avoids a blank first
  /// frame before the coordinator stream emits.
  final TransferTask? task;

  const TransferDetailPage({
    super.key,
    required this.container,
    this.transferId,
    this.peerDeviceId,
    this.batchId,
    this.task,
  }) : assert(
         transferId != null ||
             peerDeviceId != null ||
             batchId != null ||
             task != null,
       );

  static Future<void> open(
    BuildContext context,
    AppContainer container, {
    String? transferId,
    String? peerDeviceId,
    String? batchId,
    TransferTask? task,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransferDetailPage(
          container: container,
          transferId: transferId,
          peerDeviceId: peerDeviceId,
          batchId: batchId,
          task: task,
        ),
      ),
    );
  }

  @override
  State<TransferDetailPage> createState() => _TransferDetailPageState();
}

class _TransferDetailPageState extends State<TransferDetailPage> {
  StreamSubscription<List<TransferTask>>? _listSub;
  StreamSubscription<TransferProgress>? _progressSub;
  List<TransferTask> _peerTasks = const [];
  TransferTask? _task;
  TransferBatch? _batch;
  String? _failure;
  bool _sharingAgain = false;
  bool _retrying = false;
  final DateTime _openedAt = DateTime.now().subtract(
    const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    final coordinator = widget.container.fileSharingCoordinator;
    if (widget.task != null) _attach(widget.task);
    _onTransfers(coordinator.allTransfers);
    _listSub = coordinator.activeTransfersStream.listen(_onTransfers);
  }

  TransferBatch? _resolveBatch() {
    final coordinator = widget.container.fileSharingCoordinator;
    if (widget.batchId != null) return coordinator.getBatch(widget.batchId!);
    final byId = widget.transferId ?? widget.task?.transferId;
    if (byId != null) return coordinator.batchForTask(byId);
    final peer = widget.peerDeviceId;
    if (peer == null) return null;
    final latest = coordinator.latestBatchForPeer(peer, outbound: true);
    return latest != null && latest.createdAt.isAfter(_openedAt)
        ? latest
        : null;
  }

  void _onTransfers(List<TransferTask> all) {
    final batch = _resolveBatch();
    final byId = widget.transferId ?? widget.task?.transferId;

    List<TransferTask> relevant;
    TransferTask? focus;
    if (batch != null) {
      relevant = [
        for (var i = 0; i < batch.fileCount; i++)
          if (batch.tasks[i] != null) batch.tasks[i]!,
      ];
      // Prefer the file currently moving; otherwise the latest one started.
      focus =
          relevant.where((t) => _isActive(t.status)).firstOrNull ??
          (relevant.isNotEmpty ? relevant.last : null);
    } else if (byId != null) {
      relevant = all.where((t) => t.transferId == byId).toList();
      focus = relevant.isEmpty ? _task : relevant.first;
    } else {
      relevant = all
          .where((t) => t.remoteDeviceId == widget.peerDeviceId)
          .toList();
      focus =
          relevant.where((t) => _isActive(t.status)).firstOrNull ??
          (relevant.isNotEmpty ? relevant.first : _task);
    }
    if (!identical(focus, _task)) _attach(focus);
    if (mounted) {
      setState(() {
        _peerTasks = relevant;
        _batch = batch;
      });
    }
  }

  void _attach(TransferTask? task) {
    _progressSub?.cancel();
    _task = task;
    _failure = null;
    if (task == null) return;
    _progressSub = task.progressStream.listen(
      (_) {
        if (mounted) setState(() {});
      },
      onError: (_) {},
      onDone: () {
        if (mounted) setState(() {});
      },
    );
    final wasFinished = task.status == TransferStatus.completed;
    task.done.then(
      (_) {
        // A gentle tick when a file finishes while the user is watching.
        if (!wasFinished && mounted) HapticFeedback.lightImpact();
        if (mounted) setState(() {});
      },
      onError: (Object e) {
        if (mounted && identical(_task, task)) {
          setState(() => _failure = _describeFailure(e));
        }
      },
    );
  }

  String _describeFailure(Object e) {
    if (e is TransferChecksumMismatchException) {
      return 'The received file did not match the original, so it was discarded.';
    }
    if (e is TransferVerificationTimeoutException) {
      return 'All data was sent, but the other device never confirmed the file.';
    }
    if (e is TransferConnectionException) {
      return 'The connection was lost before the transfer finished.';
    }
    if (e is TransferTimeoutException) {
      return 'The other device stopped responding.';
    }
    if (e is InsufficientStorageException) {
      return 'Not enough free space: needs ${formatBytes(e.requiredBytes)}, '
          'only ${formatBytes(e.freeBytes)} free.';
    }
    if (e is TransferStorageException) {
      return e.outOfSpace
          ? 'There is not enough free storage space to save the file.'
          : 'The file could not be saved on the receiving device.';
    }
    if (e is TransferSourceException) {
      return 'The sending device could not read the file.';
    }
    if (e is TransferCancelledException) {
      return e.reason;
    }
    if (e is TransferBatchDeclinedException) {
      return e.outOfSpace
          ? 'The other device does not have enough free space for these files.'
          : e.message;
    }
    return e.toString();
  }

  @override
  void dispose() {
    _listSub?.cancel();
    _progressSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final theme = Theme.of(context);
    final batch = _batch;
    if (task == null && batch != null) {
      return _BatchWaitingView(
        container: widget.container,
        batch: batch,
        describe: _describeFailure,
      );
    }
    if (task == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Column(
          children: [
            ConnectionAttemptCard(
              container: widget.container,
              peerId: widget.peerDeviceId,
            ),
            Expanded(
              child: Center(
                child: Text(
                  'Preparing transfer…',
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final inbound = task is InboundTransferTask;
    final coordinator = widget.container.fileSharingCoordinator;
    final peer =
        coordinator.getPeerForTask(task.transferId) ??
        coordinator.getKnownPeer(task.remoteDeviceId);
    final peerName = peer?.displayName ?? 'nearby device';
    final status = task.status;

    final destination = task is InboundTransferTask ? task.destination : null;
    if (task.metadata.payloadType == PayloadType.contact &&
        status == TransferStatus.completed &&
        destination is FilePayloadDestination) {
      return _ReceivedContactView(
        container: widget.container,
        task: task,
        path: destination.targetFilePath,
        senderName: peerName,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_title(status, inbound)),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            const SizedBox(height: 12),
            Center(
              child: _ProgressRing(task: task, failed: _failure != null),
            ),
            const SizedBox(height: 28),
            Text(
              task.metadata.fileName,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              formatBytes(task.metadata.totalBytes),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            _PeerRow(
              name: peerName,
              seed: task.remoteDeviceId,
              inbound: inbound,
            ),
            const SizedBox(height: 20),
            _StatusMessage(task: task, peerName: peerName, failure: _failure),
            const SizedBox(height: 16),
            if (_isActive(status))
              _LiveStats(container: widget.container, task: task),
            if (status == TransferStatus.completed)
              _FinishedTransferStats(container: widget.container, task: task),
            if (batch != null && batch.fileCount > 1) ...[
              const SizedBox(height: 24),
              _BatchSummary(batch: batch, focus: task),
            ] else if (_peerTasks.length > 1) ...[
              const SizedBox(height: 24),
              _BatchList(tasks: _peerTasks, focus: task),
            ],
            const SizedBox(height: 28),
            ..._actions(context, task, inbound),
          ],
        ),
      ),
    );
  }

  String _title(TransferStatus status, bool inbound) {
    switch (status) {
      case TransferStatus.completed:
        return 'Transfer complete';
      case TransferStatus.failed:
        return 'Transfer failed';
      case TransferStatus.cancelled:
        return 'Transfer cancelled';
      case TransferStatus.verifying:
        return 'Verifying';
      default:
        return inbound ? 'Receiving' : 'Sending';
    }
  }

  List<Widget> _actions(BuildContext context, TransferTask task, bool inbound) {
    final status = task.status;
    final batch = _batch;
    final batchRunning = batch != null && !batch.isFinished;
    if (batchRunning && batch.outbound && batch.fileCount > 1) {
      return [
        OutlinedButton.icon(
          onPressed: () => task.cancel('Cancelled by user'),
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cancel this file'),
        ),
      ];
    }
    if (_isActive(status) && status != TransferStatus.verifying) {
      return [
        OutlinedButton.icon(
          onPressed: () => task.cancel('Cancelled by user'),
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cancel'),
        ),
      ];
    }
    if (status == TransferStatus.verifying) return const [];

    final coordinator = widget.container.fileSharingCoordinator;
    final destination = task is InboundTransferTask ? task.destination : null;
    final canOpen =
        status == TransferStatus.completed &&
        destination is FilePayloadDestination &&
        !isApkFile(destination.targetFilePath);
    final canShareAgain = coordinator.getKnownPeer(task.remoteDeviceId) != null;

    final canRetry =
        batch != null &&
        batch.outbound &&
        batch.isFinished &&
        batch.failures.isNotEmpty;

    return [
      if (canRetry) ...[
        FilledButton.icon(
          onPressed: _retrying ? null : () => _retryFailed(batch),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(
            _retrying
                ? 'Retrying…'
                : 'Retry ${batch.failedCount} failed file${batch.failedCount == 1 ? '' : 's'}',
          ),
        ),
        const SizedBox(height: 10),
      ],
      if (canOpen)
        FilledButton.icon(
          onPressed: () async {
            final path = destination.targetFilePath;
            final opened = await widget.container.platformService.openFile(
              path,
              mimeType: task.metadata.mimeType,
            );
            if (!opened && context.mounted) {
              showVayuNotice(context, 'Saved in Downloads/Vayu');
            }
          },
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Open file'),
        ),
      if (canShareAgain) ...[
        const SizedBox(height: 10),
        (canOpen ? OutlinedButton.icon : FilledButton.icon)(
          onPressed: _sharingAgain ? null : () => _shareAgain(task),
          icon: const Icon(Icons.replay_rounded),
          label: Text(_sharingAgain ? 'Choosing file…' : 'Share again'),
        ),
      ],
      const SizedBox(height: 10),
      TextButton(
        onPressed: () {
          for (final t in batch?.tasks.values ?? [task]) {
            coordinator.dismissCompletedTask(t.transferId);
          }
          Navigator.of(context).maybePop();
        },
        child: const Text('Done'),
      ),
    ];
  }

  Future<void> _retryFailed(TransferBatch batch) async {
    setState(() => _retrying = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.container.fileSharingCoordinator.retryFailedFiles(
        batch.batchId,
      );
    } catch (e) {
      showVayuNotice(
        null,
        messenger: messenger,
        _describeFailure(e),
        tone: VayuNoticeTone.problem,
      );
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _shareAgain(TransferTask task) async {
    setState(() => _sharingAgain = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final next = await widget.container.fileSharingCoordinator.shareAgain(
        task.remoteDeviceId,
      );
      if (next != null && mounted) {
        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (_) => TransferDetailPage(
              container: widget.container,
              transferId: next.transferId,
            ),
          ),
        );
      }
    } catch (e) {
      showVayuNotice(
        null,
        messenger: messenger,
        friendlyError(e),
        tone: VayuNoticeTone.problem,
      );
    } finally {
      if (mounted) setState(() => _sharingAgain = false);
    }
  }
}

class _ProgressRing extends StatelessWidget {
  final TransferTask task;
  final bool failed;

  const _ProgressRing({required this.task, required this.failed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final status = task.status;
    final progress = latestProgressOf(task);
    final fraction = status == TransferStatus.completed
        ? 1.0
        : (progress?.fraction ?? 0.0);

    final Color ringColor;
    final Widget center;
    if (status == TransferStatus.completed) {
      ringColor = palette.success;
      center = Icon(
        Icons.check_rounded,
        key: const ValueKey('done'),
        size: 72,
        color: palette.success,
      );
    } else if (failed || status == TransferStatus.failed) {
      ringColor = palette.danger;
      center = Icon(
        Icons.priority_high_rounded,
        key: const ValueKey('failed'),
        size: 64,
        color: palette.danger,
      );
    } else if (status == TransferStatus.cancelled) {
      ringColor = theme.colorScheme.outline;
      center = Icon(
        Icons.block_rounded,
        key: const ValueKey('cancelled'),
        size: 56,
        color: theme.colorScheme.onSurfaceVariant,
      );
    } else {
      ringColor = theme.colorScheme.secondary;
      center = Column(
        key: const ValueKey('moving'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${(fraction * 100).floor()}%',
            style: theme.textTheme.displaySmall,
          ),
          if (status == TransferStatus.verifying)
            Text('Verifying', style: theme.textTheme.labelMedium),
        ],
      );
    }

    final waiting =
        status == TransferStatus.idle ||
        status == TransferStatus.verifying ||
        status == TransferStatus.connecting ||
        (task is OutboundTransferTask &&
            (task as OutboundTransferTask).awaitingAcceptance);

    return Semantics(
      label: 'Transfer progress',
      value: '${(fraction * 100).floor()} percent',
      child: SizedBox(
        width: 196,
        height: 196,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                // Indeterminate only while waiting on the peer, never as fake progress.
                value: waiting && fraction == 0 ? null : fraction,
                strokeWidth: 10,
                strokeCap: StrokeCap.round,
                color: ringColor,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            // The tick (or cross) replaces the percentage with a short
            // fade and grow; the percentage itself never animates.
            VayuSwitcher(child: center),
          ],
        ),
      ),
    );
  }
}

class _PeerRow extends StatelessWidget {
  final String name;
  final String seed;
  final bool inbound;

  const _PeerRow({
    required this.name,
    required this.seed,
    required this.inbound,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        DeviceAvatar(name: name, seed: seed, size: 32),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            inbound ? 'From $name' : 'To $name',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        const SizedBox(width: 10),
        Icon(Icons.lock_rounded, size: 16, color: theme.colorScheme.secondary),
        const SizedBox(width: 4),
        Text(
          'Encrypted',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.secondary,
          ),
        ),
      ],
    );
  }
}

class _StatusMessage extends StatelessWidget {
  final TransferTask task;
  final String peerName;
  final String? failure;

  const _StatusMessage({
    required this.task,
    required this.peerName,
    required this.failure,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final inbound = task is InboundTransferTask;
    final String text;
    Color? color;

    switch (task.status) {
      case TransferStatus.idle:
      case TransferStatus.queued:
      case TransferStatus.connecting:
        text = inbound ? 'Starting…' : 'Waiting for $peerName to accept';
        break;
      case TransferStatus.transferring:
        final waiting =
            task is OutboundTransferTask &&
            (task as OutboundTransferTask).awaitingAcceptance;
        text = waiting
            ? 'Waiting for $peerName to accept'
            : inbound
            ? 'Receiving securely'
            : 'Sending securely';
        break;
      case TransferStatus.paused:
        text = 'Paused';
        break;
      case TransferStatus.verifying:
        text = 'Checking the file arrived intact';
        break;
      case TransferStatus.completed:
        text = inbound
            ? 'Verified and saved'
            : 'Delivered and verified by $peerName';
        color = palette.success;
        break;
      case TransferStatus.failed:
        text = failure ?? 'The transfer did not complete.';
        color = palette.danger;
        break;
      case TransferStatus.cancelled:
        text = failure ?? 'The transfer was cancelled.';
        break;
    }

    return Text(
      text,
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyLarge?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
        fontWeight: color != null ? FontWeight.w600 : null,
      ),
    );
  }
}

class _LiveStats extends StatelessWidget {
  final AppContainer container;
  final TransferTask task;

  const _LiveStats({required this.container, required this.task});

  @override
  Widget build(BuildContext context) {
    final progress = latestProgressOf(task);
    if (progress == null || task.status != TransferStatus.transferring) {
      return const SizedBox.shrink();
    }
    final remaining = formatRemaining(progress.etaSeconds);
    final route = routeLabel(
      container.fileSharingCoordinator.routeOfTask(task.transferId),
    );
    return Row(
      children: [
        if (route != null) _Stat(label: 'Shared via', value: route),
        _Stat(
          label: 'Transferred',
          value:
              '${formatBytes(progress.bytesTransferred)} of ${formatBytes(progress.totalBytes)}',
        ),
        _Stat(
          label: 'Speed',
          value: progress.speedBytesPerSecond > 0
              ? formatSpeed(progress.speedBytesPerSecond)
              : '—',
        ),
        _Stat(label: 'Time left', value: remaining ?? '—'),
      ],
    );
  }
}

class _FinishedTransferStats extends StatelessWidget {
  final AppContainer container;
  final TransferTask task;

  const _FinishedTransferStats({required this.container, required this.task});

  @override
  Widget build(BuildContext context) {
    final log = container.transferStatsLog;
    TransferStats? stats;
    for (final entry in log?.recent ?? const <TransferStats>[]) {
      if (entry.transferId == task.transferId) {
        stats = entry;
        break;
      }
    }
    BatchStats? batch;
    if (stats?.batchId != null) {
      for (final entry in log!.batches()) {
        if (entry.batchId == stats!.batchId) {
          batch = entry;
          break;
        }
      }
    }
    if (stats == null) return const SizedBox.shrink();
    final route = routeLabel(
      container.fileSharingCoordinator.routeOfTask(task.transferId) ??
          stats.link,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        children: [
          Text(
            '${route == null ? '' : 'Shared via $route  ·  '}Time taken: ${_durationLabel(stats.elapsed)}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (batch != null && batch.files > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Folder: ${batch.files} files  ·  ${_durationLabel(batch.wallTime)} total',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;

  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Shown before any file of a batch has started: waiting for the receiver's
/// answer, or the reason the batch did not go ahead.
class _BatchWaitingView extends StatelessWidget {
  final AppContainer container;
  final TransferBatch batch;
  final String Function(Object) describe;

  const _BatchWaitingView({
    required this.container,
    required this.batch,
    required this.describe,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final peerName =
        container.fileSharingCoordinator
            .getKnownPeer(batch.peerDeviceId)
            ?.displayName ??
        'the other device';
    final refused =
        batch.state == TransferBatchState.declined ||
        batch.state == TransferBatchState.failed;
    final error = batch.error;
    final String message;
    if (refused) {
      message = error != null ? describe(error) : 'The files were not sent.';
    } else if (batch.outbound) {
      message = 'Waiting for $peerName to accept';
    } else {
      message = 'Waiting for the first file…';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(refused ? 'Not sent' : 'Sending'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
          children: [
            ConnectionAttemptCard(
              container: container,
              peerId: batch.peerDeviceId,
            ),
            Center(
              child: SizedBox(
                width: 120,
                height: 120,
                child: refused
                    ? Icon(Icons.block_rounded, size: 72, color: palette.danger)
                    : const CircularProgressIndicator(strokeWidth: 8),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              '${batch.fileCount} files · ${formatBytes(batch.totalBytes)}',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: refused
                    ? palette.danger
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            if (refused)
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Close'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Batch overview: byte-weighted progress for the whole batch and the state
/// of every file, including ones not started yet.
class _BatchSummary extends StatelessWidget {
  final TransferBatch batch;
  final TransferTask focus;

  const _BatchSummary({required this.batch, required this.focus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final total = batch.totalBytes;
    final done = batch.bytesDone(latestProgressOf);
    final fraction = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    final failed = batch.failedCount;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                batch.isFinished
                    ? '${batch.completedCount} of ${batch.fileCount} files done'
                          '${failed > 0 ? ' · $failed failed' : ''}'
                    : '${batch.outbound ? 'Sending' : 'Receiving'} '
                          '${(batch.completedCount + failed + 1).clamp(1, batch.fileCount)}'
                          ' of ${batch.fileCount}…',
                style: theme.textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              child: LinearProgressIndicator(
                value: fraction,
                semanticsLabel: 'Files progress',
                semanticsValue: '${(fraction * 100).round()}%',
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                color: failed > 0 && batch.isFinished
                    ? palette.danger
                    : theme.colorScheme.secondary,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Text(
                _batchTimeLabel(batch, done, total),
                style: theme.textTheme.bodySmall,
              ),
            ),
            for (var i = 0; i < batch.fileCount; i++)
              _fileRow(context, i, palette),
          ],
        ),
      ),
    );
  }

  String _batchTimeLabel(TransferBatch batch, int done, int total) {
    final elapsed = DateTime.now().difference(batch.createdAt);
    final remaining = total - done;
    var speed = 0.0;
    for (final task in batch.tasks.values) {
      if (task.status == TransferStatus.transferring) {
        speed += latestProgressOf(task)?.speedBytesPerSecond ?? 0;
      }
    }
    final eta = !batch.isFinished && speed > 0 && remaining > 0
        ? _durationLabel(Duration(seconds: (remaining / speed).ceil()))
        : null;
    return '${formatBytes(done)} of ${formatBytes(total)}  ·  '
        'Elapsed ${_durationLabel(elapsed)}'
        '${eta == null ? '' : '  ·  About $eta left'}';
  }

  Widget _fileRow(BuildContext context, int i, VayuPalette palette) {
    final task = batch.tasks[i];
    final failed = batch.failures.containsKey(i);
    final completed = task?.status == TransferStatus.completed;
    final IconData icon;
    Color? color;
    if (completed) {
      icon = Icons.check_circle_rounded;
      color = palette.success;
    } else if (failed) {
      icon = Icons.error_rounded;
      color = palette.danger;
    } else if (task != null && _isActive(task.status)) {
      icon = Icons.sync_rounded;
    } else {
      icon = Icons.schedule_rounded;
    }
    return ListTile(
      dense: true,
      selected: task != null && identical(task, focus),
      leading: Icon(icon, color: color),
      title: Text(
        batch.fileNames[i],
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(formatBytes(batch.fileSizes[i])),
    );
  }
}

class _BatchList extends StatelessWidget {
  final List<TransferTask> tasks;
  final TransferTask focus;

  const _BatchList({required this.tasks, required this.focus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final done = tasks
        .where((t) => t.status == TransferStatus.completed)
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                '$done of ${tasks.length} files done',
                style: theme.textTheme.titleSmall,
              ),
            ),
            for (final t in tasks)
              ListTile(
                dense: true,
                selected: identical(t, focus),
                leading: Icon(
                  t.status == TransferStatus.completed
                      ? Icons.check_circle_rounded
                      : t.status == TransferStatus.failed
                      ? Icons.error_rounded
                      : Icons.insert_drive_file_outlined,
                  color: t.status == TransferStatus.completed
                      ? palette.success
                      : t.status == TransferStatus.failed
                      ? palette.danger
                      : null,
                ),
                title: Text(
                  t.metadata.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(formatBytes(t.metadata.totalBytes)),
              ),
          ],
        ),
      ),
    );
  }
}

/// A verified contact card waiting for the user's decision (Phase 10).
///
/// Nothing is written to the address book here: "Save to contacts" hands the
/// original card to the phone's contacts app, where the user confirms it.
class _ReceivedContactView extends StatefulWidget {
  final AppContainer container;
  final TransferTask task;
  final String path;
  final String senderName;

  const _ReceivedContactView({
    required this.container,
    required this.task,
    required this.path,
    required this.senderName,
  });

  @override
  State<_ReceivedContactView> createState() => _ReceivedContactViewState();
}

class _ReceivedContactViewState extends State<_ReceivedContactView> {
  ContactCard? _card;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    ContactCard? card;
    try {
      card = ContactCard.tryParse(await File(widget.path).readAsBytes());
    } catch (_) {}
    if (mounted) {
      setState(() {
        _card = card;
        _loaded = true;
      });
    }
  }

  Future<void> _discard() async {
    try {
      await File(widget.path).delete();
    } catch (_) {}
    widget.container.fileSharingCoordinator.dismissCompletedTask(
      widget.task.transferId,
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = VayuPalette.of(context);
    final card = _card;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact received'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (!_loaded)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (card == null) ...[
              const SizedBox(height: 24),
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: palette.danger,
              ),
              const SizedBox(height: 12),
              Text(
                'This contact card could not be read, so it was not offered for saving.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
            ] else ...[
              const SizedBox(height: 12),
              Center(
                child: DeviceAvatar(
                  name: card.displayName,
                  seed: card.displayName,
                  size: 88,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                card.displayName,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              if (card.organization != null) ...[
                const SizedBox(height: 4),
                Text(
                  card.organization!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.verified_rounded,
                    size: 16,
                    color: palette.success,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'From ${widget.senderName}, verified intact',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.success,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Card(
                child: Column(
                  children: [
                    for (final phone in card.phones)
                      ListTile(
                        leading: const Icon(Icons.call_outlined),
                        title: Text(phone),
                      ),
                    for (final email in card.emails)
                      ListTile(
                        leading: const Icon(Icons.mail_outline_rounded),
                        title: Text(email),
                      ),
                    if (card.phones.isEmpty && card.emails.isEmpty)
                      const ListTile(title: Text('No phone numbers or emails')),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: () => widget.container.platformService.openFile(
                  widget.path,
                  mimeType: 'text/x-vcard',
                ),
                icon: const Icon(Icons.person_add_alt_rounded),
                label: const Text('Save to contacts'),
              ),
            ],
            const SizedBox(height: 10),
            TextButton(
              onPressed: _discard,
              child: Text(card == null ? 'Delete' : 'Discard'),
            ),
          ],
        ),
      ),
    );
  }
}
