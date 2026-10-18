import 'dart:async';
import 'dart:math';

import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/wifi_direct_service.dart';
import 'package:vayu/domain/connection/link_upgrade_payloads.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
// Same addressing helper the transfer engine uses for every packet.
import 'package:vayu/core/transfer/transfer_task_impl.dart'
    show parseIdTo16Bytes;

/// A Wi-Fi Direct group this phone joined for one peer.
class UpgradedLink {
  /// Address and port of the peer's Vayu server inside the group.
  final String host;
  final int port;

  /// Group channel as the host reported it (0 when unknown).
  final int frequencyMhz;

  /// Leaves the group (the phone returns to its normal Wi-Fi).
  final Future<void> Function() leave;

  const UpgradedLink({
    required this.host,
    required this.port,
    required this.frequencyMhz,
    required this.leave,
  });
}

/// The peer would not host a group, or joining it failed.
class LinkUpgradeException implements Exception {
  /// Set when the peer declined; null when this phone could not join.
  final LinkUpgradeDeclineReason? declined;
  final String message;

  const LinkUpgradeException(this.message, {this.declined});

  @override
  String toString() => 'LinkUpgradeException: $message';
}

/// Moves a session found over Bluetooth onto Wi-Fi Direct.
///
/// Asking phone: sends [LinkUpgradeRequest] inside the encrypted session,
/// joins the group from the answer and returns where to connect. The Wi-Fi
/// connection then goes through the normal authenticated handshake, so it is
/// bound to the same device identity as the Bluetooth session.
///
/// Answering phone: hosts a group when [hostingBlocker] allows it (only on
/// the Receive screen, with Wi-Fi Direct allowed) and replies with its name,
/// passphrase and the Vayu port. The passphrase never leaves the session.
class LinkUpgradeService {
  final String Function() localDeviceId;
  final WifiDirectService wifiDirect;

  /// Joins a group as a plain Wi-Fi network (phones without Wi-Fi Direct).
  final LocalHotspotService hotspot;

  /// Port of this phone's Vayu server, which also listens inside the group.
  final int? Function() lanPort;

  /// Why this phone should not host a group now, or null when it may.
  final Future<LinkUpgradeDeclineReason?> Function() hostingBlocker;

  /// Open connections, to leave a joined group once its connection closes.
  final Stream<List<ConnectionSession>> sessionChanges;

  /// Waiting for the answer includes creating the group (several seconds).
  final Duration answerTimeout;

  final Map<String, Completer<LinkUpgradeResponse>> _pending = {};
  final Map<String, String> _pendingSessions = {};
  final Random _random = Random.secure();
  StreamSubscription<({SecureSession session, VayuPacket packet})>? _sub;

  LinkUpgradeService({
    required this.localDeviceId,
    required this.wifiDirect,
    required this.hotspot,
    required this.lanPort,
    required this.hostingBlocker,
    this.sessionChanges = const Stream.empty(),
    this.answerTimeout = const Duration(seconds: 30),
  });

  /// Starts answering and matching upgrade packets.
  void attach(Stream<({SecureSession session, VayuPacket packet})> packets) {
    _sub?.cancel();
    _sub = packets.listen((event) {
      final (:session, :packet) = event;
      switch (packet.packetType) {
        case PacketType.linkUpgradeRequest:
          _answer(session, packet).catchError((Object e) {
            AppLogger.warning('LinkUpgrade', 'Answering failed: $e');
          });
        case PacketType.linkUpgradeResponse:
          _onResponse(session, packet);
        default:
          break;
      }
    });
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const LinkUpgradeException('Stopped before the peer answered'),
        );
      }
    }
    _pending.clear();
    _pendingSessions.clear();
  }

  /// Whether this phone can use a 5 GHz group (sent with the request).
  Future<bool> supports5Ghz() => wifiDirect.supports5Ghz();

  /// Asks the peer of [control] to host a group, joins it and returns where
  /// its Vayu server is. Throws [LinkUpgradeException] with the reason.
  Future<UpgradedLink> upgrade(SecureSession control) async {
    final id = _newId();
    final completer = Completer<LinkUpgradeResponse>();
    _pending[id] = completer;
    _pendingSessions[id] = control.sessionId;
    final LinkUpgradeResponse response;
    try {
      final request = LinkUpgradeRequest(
        requestId: id,
        fiveGhz: await wifiDirect.supports5Ghz(),
      );
      await control.sendEncryptedPacket(
        VayuPacket(
          packetType: PacketType.linkUpgradeRequest,
          packetId: DateTime.now().microsecondsSinceEpoch,
          sourceDeviceId: parseIdTo16Bytes(localDeviceId()),
          destinationDeviceId: parseIdTo16Bytes(control.remoteDeviceId),
          payload: request.toBytes(),
        ),
      );
      response = await completer.future.timeout(
        answerTimeout,
        onTimeout: () => throw const LinkUpgradeException(
          'The other phone did not answer in time',
        ),
      );
    } finally {
      _pending.remove(id);
      _pendingSessions.remove(id);
    }

    final reason = response.declined;
    if (reason != null) {
      throw LinkUpgradeException(
        'The other phone did not start Wi-Fi Direct (${reason.name})',
        declined: reason,
      );
    }
    final name = response.networkName!;
    final passphrase = response.passphrase!;

    if (await wifiDirect.isSupported()) {
      final owner = await wifiDirect.connect(
        networkName: name,
        passphrase: passphrase,
      );
      if (owner == null) {
        throw const LinkUpgradeException(
          'Could not join the Wi-Fi Direct group',
        );
      }
      AppLogger.info(
        'LinkUpgrade',
        'Joined Wi-Fi Direct group (${response.frequencyMhz} MHz)',
      );
      return UpgradedLink(
        host: response.hostAddress!,
        port: response.port!,
        frequencyMhz: response.frequencyMhz,
        leave: wifiDirect.disconnect,
      );
    }
    // Without Wi-Fi Direct (Android 8-9) the group is joined as Wi-Fi.
    if (!await hotspot.join(ssid: name, passphrase: passphrase)) {
      throw const LinkUpgradeException('Could not join the Wi-Fi Direct group');
    }
    return UpgradedLink(
      host: response.hostAddress!,
      port: response.port!,
      frequencyMhz: response.frequencyMhz,
      leave: hotspot.leave,
    );
  }

  /// Leaves [link]'s group once [connection] is closed (the session ended
  /// after its transfers), so the phone returns to its normal Wi-Fi.
  void leaveWhenClosed(ConnectionSession connection, UpgradedLink link) {
    late final StreamSubscription<List<ConnectionSession>> sub;
    sub = sessionChanges.listen((open) {
      if (open.contains(connection)) return;
      sub.cancel();
      AppLogger.info('LinkUpgrade', 'Connection closed; leaving the group');
      link.leave().ignore();
    });
  }

  Future<void> _answer(SecureSession session, VayuPacket packet) async {
    final LinkUpgradeRequest request;
    try {
      request = LinkUpgradeRequest.fromBytes(packet.payload);
    } on FormatException catch (e) {
      AppLogger.warning('LinkUpgrade', 'Ignoring malformed request: $e');
      return;
    }
    final response = await _decide(request);
    AppLogger.info(
      'LinkUpgrade',
      response.isAccepted
          ? 'Hosting Wi-Fi Direct for ${session.remoteDeviceId} (${response.frequencyMhz} MHz)'
          : 'Declined Wi-Fi Direct for ${session.remoteDeviceId}: ${response.declined!.name}',
    );
    await session.sendEncryptedPacket(
      VayuPacket(
        packetType: PacketType.linkUpgradeResponse,
        packetId: DateTime.now().microsecondsSinceEpoch,
        sourceDeviceId: parseIdTo16Bytes(localDeviceId()),
        destinationDeviceId: parseIdTo16Bytes(session.remoteDeviceId),
        payload: response.toBytes(),
      ),
    );
  }

  Future<LinkUpgradeResponse> _decide(LinkUpgradeRequest request) async {
    LinkUpgradeResponse decline(LinkUpgradeDeclineReason reason) =>
        LinkUpgradeResponse.declined(
          requestId: request.requestId,
          declined: reason,
        );

    final blocker = await hostingBlocker();
    if (blocker != null) return decline(blocker);
    if (!await wifiDirect.isSupported()) {
      return decline(LinkUpgradeDeclineReason.unsupported);
    }
    final port = lanPort();
    if (port == null) return decline(LinkUpgradeDeclineReason.failed);

    final created = await wifiDirect.createGroup(allow5Ghz: request.fiveGhz);
    final group = created.group;
    if (group == null) {
      return decline(switch (created.error) {
        HotspotStartError.permissionDenied ||
        HotspotStartError.locationOff => LinkUpgradeDeclineReason.notAllowed,
        HotspotStartError.unsupported => LinkUpgradeDeclineReason.unsupported,
        _ => LinkUpgradeDeclineReason.failed,
      });
    }
    return LinkUpgradeResponse.accepted(
      requestId: request.requestId,
      networkName: group.credentials.ssid,
      passphrase: group.credentials.passphrase,
      hostAddress: group.credentials.hostAddress ?? defaultGroupOwnerAddress,
      port: port,
      frequencyMhz: group.frequencyMhz,
    );
  }

  void _onResponse(SecureSession session, VayuPacket packet) {
    final LinkUpgradeResponse response;
    try {
      response = LinkUpgradeResponse.fromBytes(packet.payload);
    } on FormatException catch (e) {
      AppLogger.warning('LinkUpgrade', 'Ignoring malformed answer: $e');
      return;
    }
    // Only the session that was asked may answer.
    if (_pendingSessions[response.requestId] != session.sessionId) return;
    final completer = _pending[response.requestId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(response);
    }
  }

  String _newId() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  /// Android always gives a group owner this address.
  static const String defaultGroupOwnerAddress = '192.168.49.1';
}
