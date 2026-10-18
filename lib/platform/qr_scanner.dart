import 'package:flutter/services.dart';

/// Why a scan ended without a code.
enum QrScanError { permissionDenied, cameraUnavailable, unsupported }

class QrScanException implements Exception {
  final QrScanError error;
  const QrScanException(this.error);
}

/// Opens the native camera scanner (QrScanActivity) for a Vayu pairing code,
/// or with [scan]'s `cards` also for a contact card shown on My card.
class QrScanner {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/qr_scanner',
  );

  const QrScanner();

  /// Returns the scanned `vayu://` text (or, with [cards], a vCard), or null
  /// when the user closed the scanner.
  Future<String?> scan({bool cards = false}) async {
    try {
      return await _channel.invokeMethod<String>('scan', {'cards': cards});
    } on PlatformException catch (e) {
      throw QrScanException(
        e.code == 'PERMISSION'
            ? QrScanError.permissionDenied
            : QrScanError.cameraUnavailable,
      );
    } on MissingPluginException {
      throw const QrScanException(QrScanError.unsupported);
    }
  }
}
