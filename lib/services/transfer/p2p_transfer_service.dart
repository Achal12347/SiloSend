import 'dart:async';
import 'dart:io';

import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';

import '../connection/p2p_connection_service.dart';

class P2pTransferService {
  final P2pConnectionService _connectionService;

  P2pTransferService({required this._connectionService});

  Stream<String> watchIncomingMessages() {
    return _connectionService.streamReceivedTexts();
  }

  Future<void> sendTextToClient(String clientId, String text) {
    return _connectionService.sendTextToPeer(clientId, text);
  }

  Future<void> broadcastText(String text) {
    return _connectionService.broadcastText(text);
  }

  Future<P2pFileInfo?> sendFileToClient(File file, String clientId) {
    return _connectionService.sendFileToClient(file, clientId);
  }

  Future<P2pFileInfo?> broadcastFile(
    File file, {
    List<String>? excludeClientIds,
  }) {
    return _connectionService.broadcastFile(file, excludeClientIds: excludeClientIds);
  }

  Stream<List<HostedFileInfo>> watchSentFilesInfo() {
    return _connectionService.streamSentFilesInfo();
  }

  Stream<List<ReceivableFileInfo>> watchReceivedFilesInfo() {
    return _connectionService.streamReceivedFilesInfo();
  }

  Future<bool> downloadFile(
    String fileId,
    String saveDirectory, {
    String? customFileName,
    dynamic onProgress,
  }) {
    return _connectionService.downloadFile(
      fileId,
      saveDirectory,
      customFileName: customFileName,
      onProgress: onProgress,
    );
  }

  bool get isConnected => _connectionService.isConnected;
}
