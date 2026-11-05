import 'dart:async';

import 'package:flutter/services.dart';

/// Cards that Android's own NFC tag reader delivered to Vayu: another phone
/// shared its card and Android opened (or brought forward) Vayu for it.
///
/// A card that arrived before Flutter was ready waits for [takePending].
class NfcCardInbox {
  static const MethodChannel _methods = MethodChannel('com.achyrio.vayu/nfc');
  static const EventChannel _events = EventChannel(
    'com.achyrio.vayu/nfc_cards',
  );

  static const EventChannel _tapHints = EventChannel(
    'com.achyrio.vayu/nfc_tap_hints',
  );

  const NfcCardInbox();

  /// Phones touched on a screen that does not use NFC.
  Stream<void> get tapHints =>
      _tapHints.receiveBroadcastStream().map<void>((_) {}).handleError((_) {});

  /// Cards delivered while Vayu is running.
  Stream<Uint8List> get cards => _events
      .receiveBroadcastStream()
      .where((event) => event is Uint8List)
      .cast<Uint8List>()
      .handleError((_) {});

  /// The card that launched Vayu, if any (returned once).
  Future<Uint8List?> takePending() async {
    try {
      return await _methods.invokeMethod<Uint8List>('takePendingCard');
    } catch (_) {
      return null;
    }
  }
}
