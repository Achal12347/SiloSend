import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// Receive tickets: the one-time secret a phone on the Receive screen shows
/// (QR code and NFC). A sender that scanned or tapped it proves so when
/// offering files, and only then are the files accepted without a prompt.
///
/// The proof is HMAC-SHA256(ticket, "vayu-receive-v1|sender|batch"), so it
/// is bound to the sender's authenticated device ID and to one batch: it
/// cannot be reused by another phone or for another set of files, and the
/// ticket itself never travels over the network.
class ReceiveTicket {
  ReceiveTicket._();

  static const String _label = 'vayu-receive-v1';

  /// The proof a sender attaches to [batchId] for a receiver whose ticket is
  /// [ticketHex] (a 16-byte hex secret).
  static String proof({
    required String ticketHex,
    required String senderDeviceId,
    required String batchId,
  }) {
    final key = _hexBytes(ticketHex);
    final message = utf8.encode(
      '$_label|${senderDeviceId.toLowerCase()}|${batchId.toLowerCase()}',
    );
    return crypto.Hmac(crypto.sha256, key).convert(message).toString();
  }

  /// Receiver side: true only when [proofHex] matches what [senderDeviceId]
  /// would compute for [batchId] with [ticketHex]. Constant-time compare.
  static bool verify({
    required String ticketHex,
    required String senderDeviceId,
    required String batchId,
    required String proofHex,
  }) {
    final expected = proof(
      ticketHex: ticketHex,
      senderDeviceId: senderDeviceId,
      batchId: batchId,
    );
    final given = proofHex.toLowerCase();
    if (given.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ given.codeUnitAt(i);
    }
    return diff == 0;
  }

  static List<int> _hexBytes(String hex) {
    final clean = hex.toLowerCase();
    return [
      for (var i = 0; i + 1 < clean.length; i += 2)
        int.parse(clean.substring(i, i + 2), radix: 16),
    ];
  }
}
