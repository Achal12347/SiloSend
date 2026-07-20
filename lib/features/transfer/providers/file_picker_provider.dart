import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:silosend/core/logging/app_logger.dart';

enum FilePickerStatus { initial, picking, picked, error }

class FilePickerState {
  final FilePickerStatus status;
  final List<PlatformFile> files;
  final String? errorMessage;

  const FilePickerState({
    this.status = FilePickerStatus.initial,
    this.files = const [],
    this.errorMessage,
  });

  FilePickerState copyWith({
    FilePickerStatus? status,
    List<PlatformFile>? files,
    String? errorMessage,
  }) {
    return FilePickerState(
      status: status ?? this.status,
      files: files ?? this.files,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class FilePickerNotifier extends StateNotifier<FilePickerState> {
  FilePickerNotifier() : super(const FilePickerState());

  Future<void> pickFiles() async {
    state = state.copyWith(status: FilePickerStatus.picking);
    try {
      final result = await FilePicker.pickFiles();
      state = state.copyWith(
        status: FilePickerStatus.picked,
        files: result?.files ?? state.files,
      );
    } catch (e) {
      AppLogger.error('File picker failed', error: e);
      state = state.copyWith(
        status: FilePickerStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  void clearFiles() => state = const FilePickerState();
}

final filePickerProvider =
    StateNotifierProvider<FilePickerNotifier, FilePickerState>(
      (ref) => FilePickerNotifier(),
    );
