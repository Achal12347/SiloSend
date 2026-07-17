import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/device.dart';
import '../../../models/transfer_models.dart';
import '../../../repositories/p2p_transfer_repository.dart';
import '../../../repositories/transfer_repository.dart';
import '../../../services/transfer/p2p_transfer_service.dart';
import '../../../services/transport/transport_manager.dart';
import 'connection_provider.dart';

final transferRepositoryProvider = Provider<TransferRepository>((ref) {
  final connectionService = ref.read(p2pConnectionServiceProvider);
  final service = P2pTransferService(connectionService: connectionService);
  final transportManager = SmartTransportManager(
    connectionService: connectionService,
  );
  final repository = P2pTransferRepository(
    service: service,
    transportManager: transportManager,
  );
  ref.onDispose(repository.dispose);
  return repository;
});

class FileTransferNotifier extends StateNotifier<TransferState> {
  final TransferRepository repository;
  StreamSubscription<TransferState>? _subscription;

  FileTransferNotifier({required this.repository})
    : super(repository.currentState) {
    _subscription = repository.watchState().listen((state) {
      this.state = state;
    });
  }

  Future<void> enqueueOutgoingFiles({
    required Device peer,
    required List<PlatformFile> files,
  }) async {
    final sources = <TransferSourceFile>[];

    for (final file in files) {
      final path = file.path;
      if (path == null || path.isEmpty) {
        continue;
      }

      sources.add(
        TransferSourceFile(path: path, name: file.name, size: file.size),
      );
    }

    if (sources.isEmpty) {
      throw StateError('Select files that have a valid local path.');
    }

    await repository.queueOutgoingFiles(peer: peer, files: sources);
  }

  Future<void> pauseTransfer(String transferId) {
    return repository.pauseTransfer(transferId);
  }

  Future<void> resumeTransfer(String transferId) {
    return repository.resumeTransfer(transferId);
  }

  Future<void> cancelTransfer(String transferId) {
    return repository.cancelTransfer(transferId);
  }

  Future<void> retryTransfer(String transferId) {
    return repository.retryTransfer(transferId);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final fileTransferProvider =
    StateNotifierProvider<FileTransferNotifier, TransferState>((ref) {
      final repository = ref.watch(transferRepositoryProvider);
      return FileTransferNotifier(repository: repository);
    });
