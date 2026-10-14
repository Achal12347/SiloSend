import 'dart:async';
import 'dart:io';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/transfer/file_sharing_coordinator.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';

/// Thrown when a pairing payload cannot lead to a connection.
class PairingException implements Exception {
  final String message;
  const PairingException(this.message);
  @override
  String toString() => message;
}

/// One pairing flow shared by QR codes, pairing links and NFC taps.
///
/// Showing side: [buildLocalPayload] advertises a reachable address (shared
/// Wi-Fi, or a phone-hosted hotspot), the Ed25519 identity key, a fresh secret
/// and a commitment binding the two.
/// Joining side: [join] registers that commitment so the handshake must present
/// exactly that key (trust becomes out-of-band verified, never silent TOFU),
/// joins the hotspot when needed, lists the peer in Nearby, and opens a secure
/// session through smart transport selection.
class PairingCoordinator {
  final LocalDeviceIdentity? Function() identity;
  final int? Function() lanPort;
  final String? Function() localPublicKeyHex;
  final bool Function() supportsBle;
  final DiscoveryCoordinator discoveryCoordinator;
  final SecureSessionManager secureSessionManager;
  final TransportSelector transportSelector;
  final FileSharingCoordinator fileSharingCoordinator;
  final LocalHotspotService hotspot;

  /// Resolves this phone's local IPv4 addresses (overridable in tests).
  final Future<List<String>> Function() localAddresses;

  /// Live connection sessions, used to keep a hotspot up only while needed.
  final int Function() activeSessionCount;
  final Stream<Object?> sessionChanges;

  /// How long a hotspot (hosted or joined) survives with no sessions.
  final Duration hotspotIdleTimeout;

  _IdleRelease? _hostRelease;
  _IdleRelease? _joinRelease;

  PairingCoordinator({
    required this.identity,
    required this.lanPort,
    required this.localPublicKeyHex,
    required this.supportsBle,
    required this.discoveryCoordinator,
    required this.secureSessionManager,
    required this.transportSelector,
    required this.fileSharingCoordinator,
    required this.hotspot,
    Future<List<String>> Function()? localAddresses,
    int Function()? activeSessionCount,
    Stream<Object?>? sessionChanges,
    this.hotspotIdleTimeout = const Duration(seconds: 60),
  }) : localAddresses = localAddresses ?? resolveLocalIPv4Addresses,
       activeSessionCount = activeSessionCount ?? (() => 0),
       sessionChanges = sessionChanges ?? const Stream.empty();

  /// Starts phone-to-phone Wi-Fi for a pairing screen that is about to show a
  /// code. It stays up until [releaseHotspotWhenIdle] and no session uses it.
  Future<HotspotStartResult> startHotspot() async {
    _hostRelease?.cancel();
    _hostRelease = null;
    return hotspot.start();
  }

  /// Called when the pairing screen closes: stop hosting once no session has
  /// used the hotspot for [hotspotIdleTimeout].
  void releaseHotspotWhenIdle() {
    if (!hotspot.isHosting) return;
    _hostRelease?.cancel();
    _hostRelease = _IdleRelease(
      activeSessionCount: activeSessionCount,
      changes: sessionChanges,
      timeout: hotspotIdleTimeout,
      onIdle: () {
        _hostRelease = null;
        hotspot.stop();
      },
    );
  }

  /// Builds the payload this phone shows. With [hotspotCredentials] the
  /// address is the hotspot's, and the joiner is told to join that network.
  Future<PairingPayload> buildLocalPayload({
    HotspotCredentials? hotspotCredentials,
  }) async {
    final id = identity();
    if (id == null) {
      throw const PairingException('This phone has no identity yet');
    }
    final rawPort = lanPort();
    // Port 0 means the LAN server is not listening.
    final port = (rawPort != null && rawPort > 0) ? rawPort : null;
    final address =
        hotspotCredentials?.hostAddress ?? (await localAddresses()).firstOrNull;
    final token = PairingPayload.generatePairingToken();
    final pubKey = localPublicKeyHex();

    return PairingPayload(
      deviceIdHex: id.idHex,
      displayName: id.displayName,
      supportedTransports: {
        TransportType.lan,
        if (supportsBle()) TransportType.ble,
      },
      lanAddress: port != null ? address : null,
      lanPort: address != null ? port : null,
      pairingToken: token,
      // The commitment is recomputed by the joiner from key + token, so it is
      // left out to keep the QR code small enough to scan quickly.
      ed25519PubKeyHex: pubKey,
      wifiSsid: hotspotCredentials?.ssid,
      wifiPassphrase: hotspotCredentials?.passphrase,
    );
  }

  /// Parses a pasted or scanned `vayu://pair` link (or `IP:port`) and joins.
  Future<DiscoveredPeer> joinFromText(String text) {
    final input = text.trim();
    if (input.startsWith('${PairingPayload.uriScheme}://') ||
        input.startsWith('${PairingPayload.legacyUriScheme}://')) {
      final PairingPayload payload;
      try {
        payload = PairingPayload.fromUri(Uri.parse(input));
      } on FormatException catch (e) {
        throw PairingException('This pairing link is not valid: ${e.message}');
      }
      return join(payload);
    }
    throw const PairingException(
      'Paste the full vayu://pair link shown on the other phone',
    );
  }

  /// Joins the phone described by [payload] and returns it as a Nearby peer.
  Future<DiscoveredPeer> join(PairingPayload payload) async {
    final self = identity();
    if (self != null && payload.deviceIdHex.toLowerCase() == self.idHex) {
      throw const PairingException('This is your own pairing code');
    }
    if (payload.lanAddress == null || payload.lanPort == null) {
      throw const PairingException(
        'The other phone is not on Wi-Fi. On that phone, choose '
        '"Not on the same Wi-Fi?" so it can create a direct connection.',
      );
    }

    // Bind the identity key we just received out of band to the handshake.
    final pubKey = payload.ed25519PubKeyHex;
    if (pubKey != null) {
      final committed = payload.nfcCommitmentHex != null
          ? payload
          : payload.copyWith(
              nfcCommitmentHex: PairingPayload.computeCommitmentHex(
                pubKeyHex: pubKey,
                pairingTokenHex: payload.pairingToken,
              ),
            );
      secureSessionManager.registerPendingNfcPairing(committed);
    }

    final ssid = payload.wifiSsid;
    if (ssid != null) {
      final joined = await hotspot.join(
        ssid: ssid,
        passphrase: payload.wifiPassphrase ?? '',
      );
      if (!joined) {
        throw PairingException(
          'Could not join "$ssid". Connect to it in Wi-Fi settings, then try again.',
        );
      }
      // Return to the normal network once the peer is no longer used.
      _joinRelease?.cancel();
      _joinRelease = _IdleRelease(
        activeSessionCount: activeSessionCount,
        changes: sessionChanges,
        timeout: hotspotIdleTimeout,
        onIdle: () {
          _joinRelease = null;
          hotspot.leave();
        },
      );
    }

    final peer = DiscoveredPeer(
      deviceId: payload.deviceIdHex.toLowerCase(),
      displayName: payload.displayName,
      transportType: TransportType.lan,
      availableTransports: payload.supportedTransports,
      rssi: 0,
      transportEndpoints: {
        TransportType.lan: '${payload.lanAddress}:${payload.lanPort}',
      },
      lastSeen: DateTime.now(),
    );
    discoveryCoordinator.addPairedPeer(peer);
    fileSharingCoordinator.rememberPeer(peer);

    try {
      await transportSelector.connectWithSmartSelection(
        peer,
        request: TransportSelectionRequest(targetPeer: peer),
      );
      final trust = secureSessionManager
          .getSessionForPeer(peer.deviceId)
          ?.trustLevel;
      AppLogger.info(
        'PairingCoordinator',
        'Paired with ${peer.displayName} (trust: ${trust?.name ?? 'unknown'})',
      );
    } catch (e) {
      throw PairingException(
        'Found ${peer.displayName} but could not connect. '
        'Keep Vayu open on both phones and try again.',
      );
    }
    return peer;
  }
}

/// Runs [onIdle] once no session has existed for [timeout].
class _IdleRelease {
  final int Function() activeSessionCount;
  final Duration timeout;
  final void Function() onIdle;
  late final StreamSubscription<Object?> _sub;
  Timer? _timer;
  bool _done = false;

  _IdleRelease({
    required this.activeSessionCount,
    required Stream<Object?> changes,
    required this.timeout,
    required this.onIdle,
  }) {
    _sub = changes.listen((_) => _evaluate());
    _evaluate();
  }

  void _evaluate() {
    if (_done) return;
    if (activeSessionCount() > 0) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer(timeout, () {
        if (_done || activeSessionCount() > 0) return;
        cancel();
        onIdle();
      });
    }
  }

  void cancel() {
    _done = true;
    _timer?.cancel();
    _sub.cancel();
  }
}

/// Local IPv4 addresses on Wi-Fi, hotspot, Ethernet or USB tethering
/// interfaces, best candidate first. Cellular addresses are excluded because
/// they cannot reach a nearby phone.
Future<List<String>> resolveLocalIPv4Addresses() async {
  const prefixes = [
    'wlan',
    'swlan',
    'ap',
    'softap',
    'eth',
    'en',
    'rndis',
    'usb',
  ];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final ranked = <(int, String)>[];
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      final rank = prefixes.indexWhere(name.startsWith);
      final desktop = !Platform.isAndroid;
      if (rank < 0 && !desktop) continue;
      for (final addr in iface.addresses) {
        if (addr.isLoopback || addr.isLinkLocal) continue;
        ranked.add((rank < 0 ? prefixes.length : rank, addr.address));
      }
    }
    ranked.sort((a, b) => a.$1.compareTo(b.$1));
    return ranked.map((r) => r.$2).toList();
  } catch (_) {
    return const [];
  }
}
