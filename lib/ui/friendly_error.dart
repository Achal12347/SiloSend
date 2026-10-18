import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/errors/app_error.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/domain/transfer/transfer_packet_payloads.dart';
import 'package:vayu/ui/format.dart';

/// One short, plain sentence for an error shown to the user.
///
/// Technical detail (exception text, stack) never reaches the screen; it is
/// already in the log where the error was caught. [peerName] makes messages
/// about another device specific.
String friendlyError(Object error, {String? peerName}) {
  final other = peerName ?? 'the other device';

  if (error is InsufficientStorageException) {
    return 'Not enough free space: needs ${formatBytes(error.requiredBytes)}, '
        'only ${formatBytes(error.freeBytes)} free.';
  }
  if (error is TransferStorageException) {
    return error.outOfSpace
        ? 'There is not enough free storage space to save the file.'
        : 'The file could not be saved on the receiving device.';
  }
  if (error is TransferSourceException) {
    return 'The sending device could not read the file.';
  }
  if (error is TransferChecksumMismatchException) {
    return 'The received file did not match the original, so it was discarded.';
  }
  if (error is TransferVerificationTimeoutException) {
    return 'All data was sent, but $other never confirmed the file.';
  }
  if (error is TransferConnectionException) {
    return 'The connection to $other was lost. Send again to continue where it stopped.';
  }
  if (error is TransferTimeoutException) {
    return '$other stopped responding.';
  }
  if (error is TransferBatchDeclinedException &&
      error.reason == TransferCancelReason.notReceiving) {
    return "$other isn't receiving right now. Ask them to tap Receive.";
  }
  if (error is TransferBatchDeclinedException) {
    return error.outOfSpace
        ? '$other does not have enough free space for these files.'
        : '$other declined the files.';
  }
  if (error is TransferCancelledException) {
    return error.reason;
  }
  if (error is NoViableTransportException ||
      error is SocketException ||
      error is TimeoutException) {
    return 'Couldn\'t reach $other. Make sure Vayu is open on it and both '
        'phones are nearby.';
  }
  if (error is PermissionDeniedError) {
    return 'Vayu needs permission for that. You can allow it in Settings.';
  }
  if (error is PairingException) {
    return error.message;
  }
  if (error is PlatformException) {
    return 'Your phone couldn\'t complete that. Please try again.';
  }
  return 'Something went wrong. Please try again.';
}
