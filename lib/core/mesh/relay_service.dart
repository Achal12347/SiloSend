import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/mesh/relayed_connection.dart';
// Same addressing helper the transfer engine uses for every packet.
import 'package:vayu/core/transfer/transfer_task_impl.dart'
    show parseIdTo16Bytes;
import 'package:vayu/domain/mesh/relay_payloads.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';

/// No route through nearby phones (or relaying refused), with the reason.
class MeshUnavailableException implements Exception {
  final RelayRefusal? refusal;
  final String message;
  const MeshUnavailableException(this.message, {this.refusal});

  @override
  String toString() => 'MeshUnavailableException: $message';
}

/// Phase 12 mesh: reaching a phone through other Vayu phones.
///
/// A circuit A → B (→ D) → C carries the ordinary Vayu byte stream between
/// A and C. A and C run the normal handshake and authenticated key exchange
/// over it, so every relay forwards ciphertext only (and each hop is also
/// encrypted on its own). Relays learn which two phones talk, never what
/// they send. The same service plays all three roles:
///
/// * origin: [open] finds a neighbour that can reach the target (salted
///   reach query), opens the circuit and returns a [RelayedConnection];
/// * relay: forwards opens, data and closes when the user allows relaying,
///   within [maxRelayedCircuits], [maxHops] and [bytesPerSecond];
/// * target: hands a [RelayedConnection] to the connection manager like an
///   incoming socket.
///
/// Only phones whose keys are already pinned (met directly once) may be
/// reached or reach this phone: a relayed first contact could otherwise be
/// impersonated by a relay.
class RelayService {
  final String Function() localDeviceId;

  /// A direct (not relayed) established session with the device, or null.
  final SecureSession? Function(String deviceId) directSessionFor;

  /// Opens a direct session with a neighbour (never through the mesh).
  final Future<SecureSession> Function(String deviceId) connectDirect;

  /// Neighbours that may relay: phones with a direct session or nearby.
  final List<String> Function() relayCandidates;

  /// Phones this one can reach directly (answered, hashed, to reach queries).
  final List<String> Function() reachable;

  /// Whether this phone relays for others now (user setting, battery).
  final Future<bool> Function() relayingAllowed;

  /// Whether [deviceId]'s identity key is pinned (met directly before).
  final bool Function(String deviceId) isKnown;

  /// The other phone's display name for a session, if known.
  final String? Function(SecureSession session) nameOf;

  /// Relayed connections that arrive for this phone (to the connection
  /// manager, which runs the handshake as for a socket).
  final StreamController<TransportConnection> _incoming =
      StreamController<TransportConnection>.broadcast();
  Stream<TransportConnection> get incomingConnections => _incoming.stream;

  final int maxRelayedCircuits;
  final int maxHops;
  final int bytesPerSecond;
  final Duration answerTimeout;
  final Duration relayIdleTimeout;

  RelayService({
    required this.localDeviceId,
    required this.directSessionFor,
    required this.connectDirect,
    required this.relayCandidates,
    required this.reachable,
    required this.relayingAllowed,
    required this.isKnown,
    required this.nameOf,
    this.maxRelayedCircuits = 2,
    this.maxHops = 3,
    this.bytesPerSecond = 8 * 1024 * 1024,
    this.answerTimeout = const Duration(seconds: 20),
    this.relayIdleTimeout = const Duration(minutes: 2),
  });

  final Random _random = Random.secure();
  StreamSubscription<({SecureSession session, VayuPacket packet})>? _sub;
  StreamSubscription<String>? _closedSub;
  Timer? _idleTimer;

  /// Ends this phone takes part in (origin or target), by circuit ID.
  final Map<String, _End> _ends = {};

  /// Circuits this phone forwards for others, by circuit ID.
  final Map<String, _Hop> _relayed = {};

  final Map<String, Completer<RelayOpened>> _pendingOpens = {};
  final Map<String, String> _pendingOpenSession = {};
  final Map<String, Completer<ReachAnswer>> _pendingReach = {};
  final Map<String, String> _pendingReachSession = {};

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Fires when the circuits this phone relays change.
  Stream<void> get changes => _changes.stream;

  /// Connections this phone relays for others now.
  int get relayingCount => _relayed.length;

  /// Test hook: every piece this phone forwards as a relay.
  @visibleForTesting
  void Function(Uint8List piece)? debugOnForward;

  void attach({
    required Stream<({SecureSession session, VayuPacket packet})> packets,
    required Stream<String> sessionClosed,
  }) {
    _sub?.cancel();
    _sub = packets.listen((event) {
      final (:session, :packet) = event;
      try {
        switch (packet.packetType) {
          case PacketType.relayOpen:
            _onOpen(session, RelayOpen.fromBytes(packet.payload)).catchError(
              (Object e) => AppLogger.warning('Mesh', 'Open failed: $e'),
            );
          case PacketType.relayOpened:
            _onOpened(session, RelayOpened.fromBytes(packet.payload));
          case PacketType.relayData:
            _onData(session, RelayData.fromBytes(packet.payload));
          case PacketType.relayClose:
            _onClose(session, RelayClose.fromBytes(packet.payload).circuitId);
          case PacketType.reachQuery:
            _onReachQuery(
              session,
              ReachQuery.fromBytes(packet.payload),
            ).catchError(
              (Object e) =>
                  AppLogger.warning('Mesh', 'Reach answer failed: $e'),
            );
          case PacketType.reachAnswer:
            final answer = ReachAnswer.fromBytes(packet.payload);
            if (_pendingReachSession[answer.queryId] == session.sessionId) {
              _pendingReach[answer.queryId]?.complete(answer);
            }
          default:
            break;
        }
      } on FormatException catch (e) {
        AppLogger.warning('Mesh', 'Ignoring malformed mesh packet: $e');
      }
    });
    _closedSub?.cancel();
    _closedSub = sessionClosed.listen(_onSessionClosed);
  }

  /// The idle check runs only while this phone relays something.
  void _updateIdleTimer() {
    if (_relayed.isEmpty) {
      _idleTimer?.cancel();
      _idleTimer = null;
    } else {
      _idleTimer ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => _closeIdleRelays().catchError((Object _) {}),
      );
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _closedSub?.cancel();
    _idleTimer?.cancel();
    for (final end in _ends.values.toList()) {
      await end.connection.closedRemotely('mesh_stopped');
    }
    _ends.clear();
    _relayed.clear();
    await _incoming.close();
    await _changes.close();
  }

  // ---------------------------------------------------------------- origin

  /// Opens a circuit to [targetDeviceId] through nearby phones. Throws
  /// [MeshUnavailableException] with the reason when there is no route.
  Future<RelayedConnection> open(String targetDeviceId) async {
    final target = _clean(targetDeviceId);
    if (!isKnown(target)) {
      throw const MeshUnavailableException(
        'Meet this phone directly once before reaching it through others',
        refusal: RelayRefusal.notKnown,
      );
    }
    final circuitId = _newId();
    final (hop, refusal) = await _openTowards(
      RelayOpen(
        circuitId: circuitId,
        origin: _clean(localDeviceId()),
        target: target,
        hops: 1,
      ),
      exclude: {target},
    );
    if (hop == null) {
      throw MeshUnavailableException(switch (refusal) {
        RelayRefusal.off => 'Nearby phones do not relay right now',
        RelayRefusal.busy => 'The phone in between is busy relaying',
        RelayRefusal.tooFar => 'That phone is too many phones away',
        RelayRefusal.notKnown =>
          'That phone does not know this one yet: meet directly once',
        _ => 'No nearby phone can reach it',
      }, refusal: refusal);
    }
    return _makeEnd(circuitId, hop);
  }

  /// Sends [open] to a neighbour that is (or reaches) its target and waits
  /// for the answer. Returns the hop session, or why none worked.
  Future<(SecureSession?, RelayRefusal?)> _openTowards(
    RelayOpen open, {
    required Set<String> exclude,
  }) async {
    RelayRefusal? last;
    for (final hop in await _hopsTowards(open.target, exclude)) {
      final answer = await _ask(hop, open);
      if (answer == null) {
        last ??= RelayRefusal.unreachable;
        continue;
      }
      if (answer.ok) return (hop, null);
      last = answer.refusal;
    }
    return (null, last ?? RelayRefusal.unreachable);
  }

  /// Sessions to try for [target]: a direct one, else neighbours whose reach
  /// answer lists it (and that relay now).
  Future<List<SecureSession>> _hopsTowards(
    String target,
    Set<String> exclude,
  ) async {
    // A relay forwards straight to the target when it can; the origin got
    // here because it cannot (it excludes the target).
    final direct = exclude.contains(target) ? null : directSessionFor(target);
    if (direct != null && direct.isEstablished) return [direct];
    // Heard nearby but not connected yet: connect to it directly.
    if (!exclude.contains(target) && reachable().map(_clean).contains(target)) {
      try {
        return [await connectDirect(target)];
      } catch (_) {
        // Not reachable after all; look for a relay below.
      }
    }
    // Neighbours that reach the target directly first; then other relaying
    // neighbours, which look further on (bounded by [maxHops]).
    final hops = <SecureSession>[];
    final further = <SecureSession>[];
    for (final candidate in relayCandidates().take(6)) {
      final id = _clean(candidate);
      if (exclude.contains(id) || id == _clean(localDeviceId())) continue;
      SecureSession session;
      try {
        session = directSessionFor(id) ?? await connectDirect(id);
      } catch (e) {
        continue;
      }
      final salt = _newId();
      final answer = await _query(session, salt);
      if (answer == null || !answer.relaying) continue;
      if (answer.hashes.contains(ReachAnswer.hashOf(salt, target))) {
        hops.add(session);
      } else {
        further.add(session);
      }
    }
    return [...hops, ...further];
  }

  Future<ReachAnswer?> _query(SecureSession session, String salt) async {
    final id = _newId();
    final completer = Completer<ReachAnswer>();
    _pendingReach[id] = completer;
    _pendingReachSession[id] = session.sessionId;
    try {
      await _send(
        session,
        PacketType.reachQuery,
        ReachQuery(queryId: id, salt: salt).toBytes(),
      );
      return await completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    } finally {
      _pendingReach.remove(id);
      _pendingReachSession.remove(id);
    }
  }

  Future<RelayOpened?> _ask(SecureSession hop, RelayOpen open) async {
    final completer = Completer<RelayOpened>();
    _pendingOpens[open.circuitId] = completer;
    _pendingOpenSession[open.circuitId] = hop.sessionId;
    try {
      await _send(hop, PacketType.relayOpen, open.toBytes());
      // Each relay further on may search for up to [answerTimeout] itself.
      final hopsLeft = max(1, maxHops - open.hops + 1);
      return await completer.future.timeout(answerTimeout * hopsLeft);
    } catch (_) {
      return null;
    } finally {
      _pendingOpens.remove(open.circuitId);
      _pendingOpenSession.remove(open.circuitId);
    }
  }

  RelayedConnection _makeEnd(String circuitId, SecureSession hop) {
    late final RelayedConnection connection;
    connection = RelayedConnection(
      circuitId: circuitId,
      viaName: nameOf(hop) ?? 'a nearby phone',
      sendPiece: (piece) => _send(
        hop,
        PacketType.relayData,
        RelayData(circuitId, piece).toBytes(),
      ),
      sendClose: () async {
        _ends.remove(circuitId);
        await _send(
          hop,
          PacketType.relayClose,
          RelayClose(circuitId).toBytes(),
        );
      },
    );
    _ends[circuitId] = _End(hop, connection);
    return connection;
  }

  // ---------------------------------------------------------------- relay

  Future<void> _onOpen(SecureSession from, RelayOpen open) async {
    Future<void> answer(RelayRefusal? refusal) => _send(
      from,
      PacketType.relayOpened,
      RelayOpened(circuitId: open.circuitId, refusal: refusal).toBytes(),
    );

    if (_ends.containsKey(open.circuitId) ||
        _relayed.containsKey(open.circuitId)) {
      return; // A repeat: already handled.
    }
    // The previous hop must be who it says the route comes from, or a relay
    // that forwards for it; the origin is checked at the target.
    if (open.target == _clean(localDeviceId())) {
      if (!isKnown(open.origin)) {
        AppLogger.info(
          'Mesh',
          'Refused a relayed connection: origin not known',
        );
        return answer(RelayRefusal.notKnown);
      }
      final end = _makeEnd(open.circuitId, from);
      if (!_incoming.isClosed) _incoming.add(end);
      AppLogger.info('Mesh', 'Relayed connection arrived via ${nameOf(from)}');
      return answer(null);
    }

    if (!await relayingAllowed()) return answer(RelayRefusal.off);
    if (_relayed.length >= maxRelayedCircuits) {
      return answer(RelayRefusal.busy);
    }
    if (open.hops >= maxHops) return answer(RelayRefusal.tooFar);

    final (next, refusal) = await _openTowards(
      RelayOpen(
        circuitId: open.circuitId,
        origin: open.origin,
        target: open.target,
        hops: open.hops + 1,
      ),
      exclude: {open.origin, _clean(from.remoteDeviceId)},
    );
    if (next == null) return answer(refusal);
    if (_relayed.length >= maxRelayedCircuits) {
      await _send(
        next,
        PacketType.relayClose,
        RelayClose(open.circuitId).toBytes(),
      );
      return answer(RelayRefusal.busy);
    }
    _relayed[open.circuitId] = _Hop(from, next);
    _updateIdleTimer();
    _changed();
    AppLogger.info(
      'Mesh',
      'Relaying a connection between ${nameOf(from)} and ${nameOf(next)}',
    );
    return answer(null);
  }

  void _onOpened(SecureSession from, RelayOpened opened) {
    if (_pendingOpenSession[opened.circuitId] != from.sessionId) return;
    final completer = _pendingOpens[opened.circuitId];
    if (completer != null && !completer.isCompleted) completer.complete(opened);
  }

  void _onData(SecureSession from, RelayData data) {
    final end = _ends[data.circuitId];
    if (end != null) {
      if (end.hop.sessionId == from.sessionId) {
        end.connection.deliver(data.data);
      }
      return;
    }
    final hop = _relayed[data.circuitId];
    if (hop == null) return;
    final to = hop.otherSide(from);
    if (to == null) return;
    hop.lastActivity = DateTime.now();
    debugOnForward?.call(data.data);
    // In order per circuit, at most [bytesPerSecond].
    hop.forwarding = hop.forwarding
        .then((_) async {
          await _throttle(data.data.length);
          await _send(to, PacketType.relayData, data.toBytes());
        })
        .catchError((Object e) {
          AppLogger.info('Mesh', 'Forwarding stopped: $e');
          _dropRelay(data.circuitId, notifyFrom: null);
        });
  }

  void _onClose(SecureSession from, String circuitId) {
    final end = _ends.remove(circuitId);
    if (end != null) {
      end.connection.closedRemotely('closed_by_route');
      return;
    }
    final hop = _relayed[circuitId];
    if (hop == null || hop.otherSide(from) == null) return;
    _dropRelay(circuitId, notifyFrom: from);
  }

  /// Ends a relayed circuit, telling the side(s) that did not end it.
  void _dropRelay(String circuitId, {SecureSession? notifyFrom}) {
    final hop = _relayed.remove(circuitId);
    if (hop == null) return;
    _updateIdleTimer();
    _changed();
    for (final side in [hop.a, hop.b]) {
      if (notifyFrom != null && side.sessionId == notifyFrom.sessionId) {
        continue;
      }
      _send(
        side,
        PacketType.relayClose,
        RelayClose(circuitId).toBytes(),
      ).catchError((Object _) {});
    }
  }

  void _onSessionClosed(String sessionId) {
    for (final entry in _ends.entries.toList()) {
      if (entry.value.hop.sessionId == sessionId) {
        _ends.remove(entry.key);
        entry.value.connection.closedRemotely('relay_link_lost');
      }
    }
    for (final entry in _relayed.entries.toList()) {
      final hop = entry.value;
      if (hop.a.sessionId == sessionId) {
        _dropRelay(entry.key, notifyFrom: hop.a);
      } else if (hop.b.sessionId == sessionId) {
        _dropRelay(entry.key, notifyFrom: hop.b);
      }
    }
  }

  Future<void> _closeIdleRelays() async {
    final now = DateTime.now();
    for (final entry in _relayed.entries.toList()) {
      if (now.difference(entry.value.lastActivity) > relayIdleTimeout) {
        AppLogger.info('Mesh', 'Closing an idle relayed connection');
        _dropRelay(entry.key);
      }
    }
    // Switched off (or battery low) while relaying: stop now.
    if (_relayed.isNotEmpty && !await relayingAllowed()) {
      for (final id in _relayed.keys.toList()) {
        _dropRelay(id);
      }
    }
  }

  Future<void> _onReachQuery(SecureSession from, ReachQuery query) async {
    final allowed = await relayingAllowed();
    final asker = _clean(from.remoteDeviceId);
    await _send(
      from,
      PacketType.reachAnswer,
      ReachAnswer(
        queryId: query.queryId,
        relaying: allowed,
        // Nothing to list when not relaying.
        hashes: allowed
            ? [
                for (final id in reachable().map(_clean).toSet())
                  if (id != asker) ReachAnswer.hashOf(query.salt, id),
              ].take(ReachAnswer.maxEntries).toList()
            : const [],
      ).toBytes(),
    );
  }

  // ---------------------------------------------------------------- shared

  int _windowBytes = 0;
  DateTime _windowStart = DateTime.now();

  Future<void> _throttle(int bytes) async {
    final now = DateTime.now();
    if (now.difference(_windowStart) >= const Duration(seconds: 1)) {
      _windowStart = now;
      _windowBytes = 0;
    }
    _windowBytes += bytes;
    if (_windowBytes > bytesPerSecond) {
      final wait = const Duration(seconds: 1) - now.difference(_windowStart);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _windowStart = DateTime.now();
      _windowBytes = bytes;
    }
  }

  Future<void> _send(SecureSession session, PacketType type, Uint8List body) =>
      session.sendEncryptedPacket(
        VayuPacket(
          packetType: type,
          packetId: DateTime.now().microsecondsSinceEpoch,
          sourceDeviceId: parseIdTo16Bytes(localDeviceId()),
          destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
          payload: body,
        ),
      );

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static String _clean(String id) => id.replaceAll('-', '').toLowerCase();

  String _newId() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class _End {
  final SecureSession hop;
  final RelayedConnection connection;
  _End(this.hop, this.connection);
}

class _Hop {
  final SecureSession a;
  final SecureSession b;
  DateTime lastActivity = DateTime.now();
  Future<void> forwarding = Future.value();

  _Hop(this.a, this.b);

  SecureSession? otherSide(SecureSession from) {
    if (from.sessionId == a.sessionId) return b;
    if (from.sessionId == b.sessionId) return a;
    return null;
  }
}
