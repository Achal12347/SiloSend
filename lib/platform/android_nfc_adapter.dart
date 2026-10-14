import 'dart:async';

import 'package:flutter/services.dart';

import 'package:vayu/core/pairing/nfc_pairing_service.dart';

/// [NfcPlatformAdapter] backed by NfcHandler / PairingHceService.
///
/// "Writing" a payload serves it through host card emulation until
/// [stopServing]; "listening" runs NFC reader mode and reports the payload a
/// tapped Vayu phone serves.
class AndroidNfcPlatformAdapter implements NfcPlatformAdapter {
  static const MethodChannel _methods = MethodChannel('com.achyrio.vayu/nfc');
  static const EventChannel _events = EventChannel(
    'com.achyrio.vayu/nfc_events',
  );

  StreamSubscription<dynamic>? _readSub;

  @override
  Future<bool> isNfcAvailable() async {
    try {
      return await _methods.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isNfcEnabled() async {
    try {
      return await _methods.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> startListening({
    required void Function(Uint8List ndefBytes) onTagDiscovered,
  }) async {
    await _readSub?.cancel();
    _readSub = _events.receiveBroadcastStream().listen((event) {
      if (event is Uint8List) onTagDiscovered(event);
    }, onError: (_) {});
    await _methods.invokeMethod<bool>('startReading');
  }

  @override
  Future<void> stopListening() async {
    await _readSub?.cancel();
    _readSub = null;
    try {
      await _methods.invokeMethod<bool>('stopReading');
    } catch (_) {}
  }

  @override
  Future<void> writeNdef(Uint8List ndefBytes) async {
    await _methods.invokeMethod<bool>('serve', {'bytes': ndefBytes});
  }

  @override
  Future<void> stopServing() async {
    try {
      await _methods.invokeMethod<bool>('stopServing');
    } catch (_) {}
  }
}
