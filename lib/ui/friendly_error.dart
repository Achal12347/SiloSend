import 'package:vayu/core/mesh/relay_service.dart';
import 'package:vayu/domain/mesh/relay_payloads.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:vayu/core/connection/link_upgrade_service.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/errors/app_error.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/domain/connection/link_upgrade_payloads.dart';
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
  if (error is LinkUpgradeException) {
    return switch (error.declined) {
      LinkUpgradeDeclineReason.notReceiving =>
        "$other isn't receiving right now. Ask them to tap Receive.",
      LinkUpgradeDeclineReason.notAllowed =>
        '$other has to allow Nearby Wi-Fi devices (and Location on older Android) to connect without a shared Wi-Fi.',
      LinkUpgradeDeclineReason.unsupported =>
        "$other can't make a direct Wi-Fi connection. Put both phones on the same Wi-Fi.",
      LinkUpgradeDeclineReason.failed =>
        "$other couldn't start a direct Wi-Fi connection. Try again.",
      null =>
        "Couldn't connect to $other over direct Wi-Fi. Move the phones closer and try again.",
    };
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
  if (error is MeshUnavailableException) {
    return switch (error.refusal) {
      RelayRefusal.notKnown =>
        "$other can't be reached through other phones until you meet once directly.",
      RelayRefusal.off =>
        "$other isn't nearby, and no phone in between relays right now.",
      RelayRefusal.busy => "The phone in between is busy. Try again soon.",
      RelayRefusal.tooFar => '$other is too many phones away.',
      _ => "$other isn't nearby, and no nearby phone can reach it.",
    };
  }
  if (error is PairingException) {
    return error.message;
  }
  if (error is PlatformException) {
    return 'Your phone couldn\'t complete that. Please try again.';
  }
  return 'Something went wrong. Please try again.';
}
