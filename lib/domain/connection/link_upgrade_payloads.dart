import 'dart:convert';
import 'dart:typed_data';

/// Asks the peer to host a Wi-Fi Direct group for this session (packet
/// 0x40). Sent only inside an authenticated, encrypted session.
class LinkUpgradeRequest {
  /// Matches the answer to the question (32 hex characters).
  final String requestId;

  /// Whether the asking phone can use a 5 GHz group. When it cannot, the
  /// host makes a 2.4 GHz group (a 5 GHz one would be invisible to it).
  final bool fiveGhz;

  const LinkUpgradeRequest({required this.requestId, required this.fiveGhz});

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(jsonEncode({'id': requestId, '5g': fiveGhz})),
  );

  static LinkUpgradeRequest fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Link upgrade request is not an object');
    }
    final id = json['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('Link upgrade request has no valid id');
    }
    return LinkUpgradeRequest(requestId: id, fiveGhz: json['5g'] == true);
  }
}

/// Why a phone did not host a group.
enum LinkUpgradeDeclineReason {
  /// The receiving phone is not on its Receive screen.
  notReceiving,

  /// Wi-Fi Direct is not allowed there (permission or Location off).
  notAllowed,

  /// The phone has no Wi-Fi Direct (or Android older than 10).
  unsupported,

  /// The group could not be created.
  failed;

  static LinkUpgradeDeclineReason parse(Object? value) =>
      LinkUpgradeDeclineReason.values.firstWhere(
        (r) => r.name == value,
        orElse: () => LinkUpgradeDeclineReason.failed,
      );
}

/// The answer (packet 0x41): the group to join and where Vayu listens on it,
/// or why there is none. Travels only inside the encrypted session, so the
/// passphrase is never visible to anyone else.
class LinkUpgradeResponse {
  final String requestId;
  final LinkUpgradeDeclineReason? declined;
  final String? networkName;
  final String? passphrase;
  final String? hostAddress;
  final int? port;

  /// Channel of the group, for diagnostics (0 when unknown).
  final int frequencyMhz;

  const LinkUpgradeResponse.accepted({
    required this.requestId,
    required String this.networkName,
    required String this.passphrase,
    required String this.hostAddress,
    required int this.port,
    this.frequencyMhz = 0,
  }) : declined = null;

  const LinkUpgradeResponse.declined({
    required this.requestId,
    required LinkUpgradeDeclineReason this.declined,
  }) : networkName = null,
       passphrase = null,
       hostAddress = null,
       port = null,
       frequencyMhz = 0;

  bool get isAccepted => declined == null;

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(
        isAccepted
            ? {
                'id': requestId,
                'ssid': networkName,
                'pass': passphrase,
                'host': hostAddress,
                'port': port,
                'mhz': frequencyMhz,
              }
            : {'id': requestId, 'declined': declined!.name},
      ),
    ),
  );

  static LinkUpgradeResponse fromBytes(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Link upgrade response is not an object');
    }
    final id = json['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('Link upgrade response has no valid id');
    }
    if (json.containsKey('declined')) {
      return LinkUpgradeResponse.declined(
        requestId: id,
        declined: LinkUpgradeDeclineReason.parse(json['declined']),
      );
    }
    final ssid = json['ssid'];
    final pass = json['pass'];
    final host = json['host'];
    final port = json['port'];
    if (ssid is! String ||
        ssid.isEmpty ||
        pass is! String ||
        host is! String ||
        InternetAddressCheck.parseIpv4(host) == null ||
        port is! int ||
        port <= 0 ||
        port > 65535) {
      throw const FormatException('Link upgrade response is incomplete');
    }
    return LinkUpgradeResponse.accepted(
      requestId: id,
      networkName: ssid,
      passphrase: pass,
      hostAddress: host,
      port: port,
      frequencyMhz: json['mhz'] is int ? json['mhz'] as int : 0,
    );
  }
}

final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');

/// Address check without dart:io (domain code stays platform-free).
abstract final class InternetAddressCheck {
  /// The four octets of a dotted IPv4 address, or null.
  static List<int>? parseIpv4(String text) {
    final parts = text.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255 || part.isEmpty) {
        return null;
      }
      octets.add(value);
    }
    return octets;
  }
}
