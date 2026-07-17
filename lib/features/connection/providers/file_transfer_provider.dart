import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum FileTransferStatus { initial, sending, sent, error }

class FileTransferState {
  final FileTransferStatus status;
  final List<PlatformFile> files;
  final String? currentFile;
  final double progress;
  final String? errorMessage;

  const FileTransferState({
    this.status = FileTransferStatus.initial,
    this.files = const [],
    this.currentFile,
    this.progress = 0.0,
    this.errorMessage,
  });

  FileTransferState copyWith({
    FileTransferStatus? status,
    List<PlatformFile>? files,
    String? currentFile,
    double? progress,
    String? errorMessage,
    bool clearError = false,
  }) {
    return FileTransferState(
      status: status ?? this.status,
      files: files ?? this.files,
      currentFile: currentFile ?? this.currentFile,
      progress: progress ?? this.progress,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class FileTransferNotifier extends StateNotifier<FileTransferState> {
  FileTransferNotifier() : super(const FileTransferState());

  Future<void> sendFiles(List<PlatformFile> files) async {
    if (files.isEmpty || state.status == FileTransferStatus.sending) return;

    state = state.copyWith(
      status: FileTransferStatus.sending,
      files: files,
      progress: 0.0,
    );

    try {
      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        state = state.copyWith(currentFile: file.name);

        for (int p = 0; p <= 10; p++) {
          await Future.delayed(const Duration(milliseconds: 100));
          final overallProgress =
              (i / files.length) + (p / 10.0) / files.length;
          state = state.copyWith(progress: overallProgress);
        }
      }

      state = state.copyWith(status: FileTransferStatus.sent, progress: 1.0);
    } catch (e) {
      state = state.copyWith(
        status: FileTransferStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  void reset() => state = const FileTransferState();
}

final fileTransferProvider =
    StateNotifierProvider<FileTransferNotifier, FileTransferState>(
      (ref) => FileTransferNotifier(),
    );
