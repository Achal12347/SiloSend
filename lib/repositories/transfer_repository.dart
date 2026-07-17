import '../models/device.dart';
import '../models/transfer_models.dart';

abstract class TransferRepository {
  TransferState get currentState;

  Stream<TransferState> watchState();

  Future<void> queueOutgoingFiles({
    required Device peer,
    required List<TransferSourceFile> files,
  });

  Future<void> pauseTransfer(String transferId);

  Future<void> resumeTransfer(String transferId);

  Future<void> cancelTransfer(String transferId);

  Future<void> retryTransfer(String transferId);

  void dispose();
}
