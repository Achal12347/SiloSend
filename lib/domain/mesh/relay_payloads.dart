import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

Map<String, dynamic> _object(Uint8List bytes, String what) {
  final json = jsonDecode(utf8.decode(bytes));
  if (json is! Map<String, dynamic>) {
    throw FormatException('$what is not an object');
  }
  return json;
}

String _id(Map<String, dynamic> json, String key, String what) {
  final value = json[key];
  if (value is! String || !_hex32.hasMatch(value)) {
    throw FormatException('$what has no valid $key');
  }
  return value;
}

/// Why a relayed connection could not be opened.
enum RelayRefusal {
  /// The phone asked to relay has relaying switched off (or its battery is
  /// low / Battery Saver is on).
  off,

  /// It already relays as many connections as it allows.
  busy,

  /// The route would be longer than the hop limit.
  tooFar,

  /// No route to the target from there.
  unreachable,

  /// The target has never met the caller directly (keys not pinned), so a
  /// relayed first contact could be impersonated; refused.
  notKnown,
}

/// Opens a circuit (packet 0x60): [origin] wants an end-to-end connection
/// with [target]; each relay passes it one hop on, adding to [hops].
/// Sent inside the hop's encrypted session. Relays learn who talks to whom
/// (needed to route), never what they say.
class RelayOpen {
  final String circuitId;
  final String origin;
  final String target;
  final int hops;

  const RelayOpen({
    required this.circuitId,
    required this.origin,
    required this.target,
    required this.hops,
  });

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({'c': circuitId, 'from': origin, 'to': target, 'h': hops}),
    ),
  );

  static RelayOpen fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'Relay open');
    final hops = json['h'];
    if (hops is! int || hops < 1 || hops > 16) {
      throw const FormatException('Relay open has no valid hop count');
    }
    return RelayOpen(
      circuitId: _id(json, 'c', 'Relay open'),
      origin: _id(json, 'from', 'Relay open'),
      target: _id(json, 'to', 'Relay open'),
      hops: hops,
    );
  }
}

/// Answer to [RelayOpen] (packet 0x61), passed back along the route.
class RelayOpened {
  final String circuitId;
  final RelayRefusal? refusal;

  const RelayOpened({required this.circuitId, this.refusal});

  bool get ok => refusal == null;

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({'c': circuitId, if (refusal != null) 'r': refusal!.name}),
    ),
  );

  static RelayOpened fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'Relay answer');
    final r = json['r'];
    return RelayOpened(
      circuitId: _id(json, 'c', 'Relay answer'),
      refusal: r == null
          ? null
          : RelayRefusal.values.where((x) => x.name == r).firstOrNull ??
                RelayRefusal.unreachable,
    );
  }
}

/// Opaque bytes of one circuit (packet 0x62): 16-byte circuit ID, then the
/// end-to-end encrypted stream between origin and target. Binary, since it
/// carries files.
class RelayData {
  /// Largest piece one packet carries.
  static const int maxPiece = 256 * 1024;

  final String circuitId;
  final Uint8List data;

  const RelayData(this.circuitId, this.data);

  Uint8List toBytes() {
    final out = Uint8List(16 + data.length);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(circuitId.substring(i * 2, i * 2 + 2), radix: 16);
    }
    out.setRange(16, out.length, data);
    return out;
  }

  static RelayData fromBytes(Uint8List bytes) {
    if (bytes.length < 16 || bytes.length > 16 + maxPiece) {
      throw const FormatException('Relay data has no valid size');
    }
    final id = StringBuffer();
    for (var i = 0; i < 16; i++) {
      id.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return RelayData(id.toString(), Uint8List.sublistView(bytes, 16));
  }
}

/// Ends a circuit (packet 0x63), passed on along the route.
class RelayClose {
  final String circuitId;
  const RelayClose(this.circuitId);

  Uint8List toBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode({'c': circuitId})));

  static RelayClose fromBytes(Uint8List bytes) =>
      RelayClose(_id(_object(bytes, 'Relay close'), 'c', 'Relay close'));
}

/// "Can you reach these phones?" (packet 0x64). The asker sends a fresh
/// [salt]; the answer lists salted hashes, so a relay does not hand its list
/// of nearby phones to anyone who asks.
class ReachQuery {
  final String queryId;
  final String salt;

  const ReachQuery({required this.queryId, required this.salt});

  Uint8List toBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode({'id': queryId, 's': salt})));

  static ReachQuery fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'Reach query');
    return ReachQuery(
      queryId: _id(json, 'id', 'Reach query'),
      salt: _id(json, 's', 'Reach query'),
    );
  }
}

/// Answer to [ReachQuery] (packet 0x65): whether this phone relays now, and
/// the salted hashes of the phones it can reach directly.
class ReachAnswer {
  static const int maxEntries = 64;

  final String queryId;
  final bool relaying;
  final List<String> hashes;

  const ReachAnswer({
    required this.queryId,
    required this.relaying,
    this.hashes = const [],
  });

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(jsonEncode({'id': queryId, 'on': relaying, 'h': hashes})),
  );

  static ReachAnswer fromBytes(Uint8List bytes) {
    final json = _object(bytes, 'Reach answer');
    final raw = json['h'];
    if (raw is! List || raw.length > maxEntries) {
      throw const FormatException('Reach answer has no valid list');
    }
    return ReachAnswer(
      queryId: _id(json, 'id', 'Reach answer'),
      relaying: json['on'] == true,
      hashes: [
        for (final h in raw)
          if (h is String && RegExp(r'^[0-9a-f]{16}$').hasMatch(h)) h,
      ],
    );
  }

  /// The salted hash of [deviceIdHex] as listed in answers.
  static String hashOf(String saltHex, String deviceIdHex) {
    final digest = sha256.convert([
      ...utf8.encode(saltHex),
      ...utf8.encode(deviceIdHex.replaceAll('-', '').toLowerCase()),
    ]);
    return digest.toString().substring(0, 16);
  }
}
