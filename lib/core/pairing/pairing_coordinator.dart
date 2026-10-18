import 'dart:async';
import 'dart:io';

import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/wifi_direct_service.dart';
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
  final WifiDirectService wifiDirect;

  /// Resolves this phone's local IPv4 addresses (overridable in tests).
  final Future<List<String>> Function() localAddresses;

  /// Live connection sessions, used to keep a hotspot up only while needed.
  final int Function() activeSessionCount;
  final Stream<Object?> sessionChanges;

  /// How long a hotspot (hosted or joined) survives with no sessions.
  final Duration hotspotIdleTimeout;

  _IdleRelease? _hostRelease;
  _IdleRelease? _joinRelease;
  _IdleRelease? _groupRelease;

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
    this.wifiDirect = const UnsupportedWifiDirectService(),
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
    if (wifiDirect.isHosting) {
      _groupRelease?.cancel();
      _groupRelease = _IdleRelease(
        activeSessionCount: activeSessionCount,
        changes: sessionChanges,
        timeout: hotspotIdleTimeout,
        onIdle: () {
          _groupRelease = null;
          wifiDirect.removeGroup();
        },
      );
    }
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
    bool wifiDirect = false,
    String? fallbackLanAddress,
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
      wifiDirect: wifiDirect && hotspotCredentials != null,
      fallbackLanAddress: fallbackLanAddress,
    );
  }

  /// For the Receive screen: a code on this phone's Wi-Fi Direct group (the
  /// fast path, Android 10+) with the shared Wi-Fi as fallback; without a
  /// group, a code on the shared Wi-Fi or, when this phone has no shared
  /// network (or [forceHotspot]), on a phone-hosted hotspot.
  /// Returns the payload (null if none could be made) and the hotspot error,
  /// if starting it failed.
  Future<(PairingPayload?, HotspotStartError?)> prepareShowableCode({
    bool forceHotspot = false,
  }) async {
    var payload = await buildLocalPayload();
    if (!forceHotspot && await wifiDirect.isSupported()) {
      _groupRelease?.cancel();
      _groupRelease = null;
      final created = await wifiDirect.createGroup();
      final group = created.group;
      if (group != null) {
        AppLogger.info(
          'PairingCoordinator',
          'Wi-Fi Direct group up (${group.frequencyMhz} MHz)',
        );
        final direct = await buildLocalPayload(
          hotspotCredentials: group.credentials,
          wifiDirect: true,
          fallbackLanAddress: payload.lanAddress,
        );
        return (direct, null);
      }
      // Otherwise carry on exactly as without Wi-Fi Direct.
      AppLogger.info(
        'PairingCoordinator',
        'No Wi-Fi Direct group (${created.error?.name}); using Wi-Fi or hotspot',
      );
    }
    if (forceHotspot && wifiDirect.isHosting) {
      // Most phones cannot host a group and a hotspot at once.
      _groupRelease?.cancel();
      _groupRelease = null;
      await wifiDirect.removeGroup();
    }
    if (payload.lanAddress == null || forceHotspot) {
      final started = await startHotspot();
      if (!started.isSuccess) {
        return (payload.lanAddress == null ? null : payload, started.error);
      }
      payload = await buildLocalPayload(
        hotspotCredentials: started.credentials,
      );
    }
    return (payload, null);
  }

  /// Sending side: joins the phone whose code was scanned or tapped and
  /// remembers its Receive ticket, so files sent to it next carry a proof
  /// (accepted without a prompt if that phone is on its Receive screen).
  Future<DiscoveredPeer> joinToSend(PairingPayload payload) async {
    final peer = await join(payload);
    fileSharingCoordinator.rememberReceiveTicket(
      peer.deviceId,
      payload.pairingToken,
    );
    return peer;
  }

  /// [joinToSend] from scanned text (a `vayu://pair` link).
  Future<DiscoveredPeer> joinToSendFromText(String text) {
    final input = text.trim();
    try {
      return joinToSend(PairingPayload.fromUri(Uri.parse(input)));
    } on FormatException {
      throw const PairingException(
        "That is not a Vayu code. Scan the code on the other phone's Receive screen.",
      );
    }
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
    if (ssid != null && payload.wifiDirect) {
      return _joinViaWifiDirect(payload, ssid);
    }
    if (ssid != null) {
      await _joinHotspot(ssid, payload.wifiPassphrase ?? '');
    }
    return _connectTo(payload, payload.lanAddress!);
  }

  /// Wi-Fi Direct first (fast, no dialog, normal Wi-Fi stays on), then the
  /// shared router, then the group joined like a hotspot (the only way for
  /// phones without Wi-Fi Direct when there is no shared router).
  Future<DiscoveredPeer> _joinViaWifiDirect(
    PairingPayload payload,
    String ssid,
  ) async {
    final passphrase = payload.wifiPassphrase ?? '';
    final groupAddress = payload.lanAddress!;
    if (await wifiDirect.isSupported()) {
      final owner = await wifiDirect.connect(
        networkName: ssid,
        passphrase: passphrase,
      );
      if (owner != null) {
        _releaseJoinWhenIdle(wifiDirect.disconnect);
        try {
          return await _connectTo(payload, groupAddress);
        } on PairingException {
          _joinRelease?.cancel();
          _joinRelease = null;
          await wifiDirect.disconnect();
        }
      }
      AppLogger.info('PairingCoordinator', 'Wi-Fi Direct join failed');
    }
    final fallback = payload.fallbackLanAddress;
    if (fallback != null) {
      try {
        return await _connectTo(payload, fallback);
      } on PairingException {
        AppLogger.info('PairingCoordinator', 'Shared Wi-Fi not reachable');
      }
    }
    await _joinHotspot(ssid, passphrase);
    return _connectTo(payload, groupAddress);
  }

  Future<void> _joinHotspot(String ssid, String passphrase) async {
    final joined = await hotspot.join(ssid: ssid, passphrase: passphrase);
    if (!joined) {
      throw PairingException(
        'Could not join "$ssid". Connect to it in Wi-Fi settings, then try again.',
      );
    }
    // Return to the normal network once the peer is no longer used.
    _releaseJoinWhenIdle(hotspot.leave);
  }

  void _releaseJoinWhenIdle(Future<void> Function() leave) {
    _joinRelease?.cancel();
    _joinRelease = _IdleRelease(
      activeSessionCount: activeSessionCount,
      changes: sessionChanges,
      timeout: hotspotIdleTimeout,
      onIdle: () {
        _joinRelease = null;
        leave();
      },
    );
  }

  Future<DiscoveredPeer> _connectTo(
    PairingPayload payload,
    String address,
  ) async {
    final peer = DiscoveredPeer(
      deviceId: payload.deviceIdHex.toLowerCase(),
      displayName: payload.displayName,
      transportType: TransportType.lan,
      availableTransports: payload.supportedTransports,
      rssi: 0,
      transportEndpoints: {TransportType.lan: '$address:${payload.lanPort}'},
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
