import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/domain/mesh/relay_payloads.dart';

/// One end of a circuit through other Vayu phones, used like any other link.
///
/// The bytes are the ordinary Vayu stream between the two end phones: the
/// connection manager runs its handshake over it and the secure session its
/// authenticated key exchange and AES-GCM, so relays forward only
/// ciphertext. Each hop additionally carries it inside its own encrypted
/// session.
class RelayedConnection extends TransportConnection {
  final String circuitId;

  /// Name of the first relay, for "through Bo" in the interface.
  final String viaName;

  /// Sends one piece over the first hop; tells the route it closed.
  final Future<void> Function(Uint8List piece) sendPiece;
  final Future<void> Function() sendClose;

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  ConnectionState _state = ConnectionState.connected;
  String? _disconnectReason;
  Future<void> _writing = Future.value();

  /// Bytes sent and received, for diagnostics.
  int bytesOut = 0;
  int bytesIn = 0;

  RelayedConnection({
    required this.circuitId,
    required this.viaName,
    required this.sendPiece,
    required this.sendClose,
  });

  @override
  String get connectionId => 'relay-$circuitId';

  @override
  TransportType get type => TransportType.relay;

  @override
  ConnectionState get state => _state;

  @override
  String? get remoteAddress => 'via $viaName';

  @override
  int? get remotePort => null;

  @override
  String? get disconnectReason => _disconnectReason;

  @override
  Stream<Uint8List> get incomingBytes => _incoming.stream;

  @override
  LinkMetrics get currentMetrics => LinkMetrics.zero;

  /// Writes are queued: concurrent callers must not interleave their pieces,
  /// or the other end would read a corrupt stream.
  @override
  Future<void> sendBytes(Uint8List data) {
    if (_state != ConnectionState.connected) {
      return Future.error(StateError('Relayed connection is closed'));
    }
    final done = _writing.then((_) async {
      for (var offset = 0; offset < data.length; offset += RelayData.maxPiece) {
        final end = min(offset + RelayData.maxPiece, data.length);
        await sendPiece(Uint8List.sublistView(data, offset, end));
      }
      bytesOut += data.length;
    });
    // A failed write fails this caller; later writes still run in order.
    _writing = done.catchError((Object _) {});
    return done;
  }

  /// Bytes the other end sent (from the relay service).
  void deliver(Uint8List data) {
    if (_state != ConnectionState.connected || _incoming.isClosed) return;
    bytesIn += data.length;
    _incoming.add(data);
  }

  @override
  Future<void> close({String? reason}) async {
    if (_state != ConnectionState.connected) return;
    _state = ConnectionState.disconnected;
    _disconnectReason = reason;
    try {
      await sendClose();
    } catch (_) {
      // The hop is gone already; nothing to tell.
    }
    await _incoming.close();
  }

  /// The circuit ended elsewhere (the other end, a relay, or the hop).
  Future<void> closedRemotely(String reason) async {
    if (_state != ConnectionState.connected) return;
    _state = ConnectionState.disconnected;
    _disconnectReason = reason;
    await _incoming.close();
  }
}
