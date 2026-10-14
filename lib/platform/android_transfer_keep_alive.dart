import 'package:flutter/services.dart';

import 'package:vayu/core/contracts/transfer_keep_alive_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';

/// Android implementation backed by the native TransferForegroundService.
class AndroidTransferKeepAlive implements TransferKeepAlive {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/transfer_service',
  );

  const AndroidTransferKeepAlive();

  @override
  Future<bool> start({
    required String title,
    required String text,
    int? progress,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('start', {
            'title': title,
            'text': text,
            'progress': progress ?? -1,
          }) ??
          false;
    } catch (e) {
      AppLogger.warning(
        'TransferKeepAlive',
        'Foreground service start failed: $e',
      );
      return false;
    }
  }

  @override
  Future<void> update({
    required String title,
    required String text,
    int? progress,
  }) async {
    try {
      await _channel.invokeMethod<bool>('update', {
        'title': title,
        'text': text,
        'progress': progress ?? -1,
      });
    } catch (_) {
      // A missed notification refresh is harmless; the next update retries.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (e) {
      AppLogger.warning(
        'TransferKeepAlive',
        'Foreground service stop failed: $e',
      );
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
