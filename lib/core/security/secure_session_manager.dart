import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/errors/app_error.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/security/short_authentication_string.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/security/auth_exchange_payload.dart';
import 'package:vayu/domain/security/crypto_identity_keypair.dart';
import 'package:vayu/domain/security/trust_level.dart';

/// Represents an out-of-band NFC pairing record awaiting transport connection.
class PendingNfcPairing {
  final String deviceIdHex;
  final Uint8List ed25519PubKey;
  final Uint8List nfcCommitment;
  final Uint8List pairingSecret;
  final DateTime receivedAt;

  PendingNfcPairing({
    required this.deviceIdHex,
    required this.ed25519PubKey,
    required this.nfcCommitment,
    required this.pairingSecret,
    required this.receivedAt,
  });

  bool get isExpired =>
      DateTime.now().difference(receivedAt) > const Duration(minutes: 5);
}

/// Orchestrates 3-way authenticated Diffie-Hellman key exchanges (PacketType.authExchange),
/// Rekey-v1 in-band key rotation, and manages active, end-to-end encrypted [SecureSessionImpl] instances.
class SecureSessionManager {
  final CryptoService cryptoService;
  final PeerTrustStore trustStore;
  final SecureKeyStore secureKeyStore;
  final LocalDeviceIdentity localIdentity;

  final Map<String, SecureSessionImpl> _sessions = {};
  final Map<String, PendingNfcPairing> _pendingNfcPairings = {};
  final Map<String, StreamSubscription<VayuPacket>> _rekeySubscriptions = {};
  final Map<String, Future<SecureSessionImpl>> _inFlightOutboundSecuring = {};
  final StreamController<SecureSessionImpl> _sessionController =
      StreamController<SecureSessionImpl>.broadcast();

  CryptoIdentityKeypair? _localKeypair;

  SecureSessionManager({
    required this.cryptoService,
    required this.trustStore,
    required this.secureKeyStore,
    required this.localIdentity,
  });

  /// The local Ed25519 identity keypair, loaded or initialized.
  CryptoIdentityKeypair? get localKeypair => _localKeypair;

  /// Reactive stream of newly established secure sessions.
  Stream<SecureSessionImpl> get secureSessions => _sessionController.stream;

  /// List of currently active, secured sessions.
  List<SecureSessionImpl> get activeSessions =>
      _sessions.values.where((s) => s.isEstablished).toList();

  /// Retrieves an active secure session by session ID.
  SecureSessionImpl? getSession(String sessionId) => _sessions[sessionId];

  /// Retrieves an active secure session by remote device ID hex.
  SecureSessionImpl? getSessionForPeer(String remoteDeviceId) {
    final clean = remoteDeviceId.replaceAll('-', '').toLowerCase();
    SecureSessionImpl? bluetooth;
    for (final session in _sessions.values) {
      if (session.remoteDeviceId.replaceAll('-', '').toLowerCase() == clean &&
          session.isEstablished) {
        // After a Wi-Fi Direct upgrade the peer has a Bluetooth session and
        // a Wi-Fi one; transfers must use the Wi-Fi one.
        if (session.connectionSession.connection.type != TransportType.ble) {
          return session;
        }
        bluetooth ??= session;
      }
    }
    return bluetooth;
  }

  /// Initializes or loads the persistent Ed25519 identity keypair from [SecureKeyStore].
  Future<CryptoIdentityKeypair> getOrInitializeLocalKeypair() async {
    if (_localKeypair != null) return _localKeypair!;

    final storedSeed = await secureKeyStore.loadIdentitySeed();
    if (storedSeed != null) {
      _localKeypair = await cryptoService.identityKeypairFromSeed(storedSeed);
      AppLogger.info(
        'SecureSessionManager',
        'Loaded persistent Ed25519 identity key (${_localKeypair!.fingerprintHex.substring(0, 16)}...)',
      );
      return _localKeypair!;
    }

    // First boot: generate fresh Ed25519 identity keypair and persist seed
    final minted = await cryptoService.generateIdentityKeypair();
    await secureKeyStore.saveIdentitySeed(minted.privateKeySeed!);
    _localKeypair = minted;

    AppLogger.info(
      'SecureSessionManager',
      'Minted and persisted fresh Ed25519 identity key (${minted.fingerprintHex.substring(0, 16)}...)',
    );
    return minted;
  }

  /// Initiates a 3-way authenticated Diffie-Hellman exchange over an outbound [connectionSession].
  /// Elevates session state from `connected` to `secured`.
  Future<SecureSessionImpl> secureOutboundConnection(
    ConnectionSession connectionSession, {
    Uint8List? nfcCommitment,
    Uint8List? pairingSecret,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final existing = _sessions[connectionSession.sessionId];
    if (existing != null && existing.isEstablished) {
      return existing;
    }

    final inFlight = _inFlightOutboundSecuring[connectionSession.sessionId];
    if (inFlight != null) {
      return await inFlight;
    }

    // Preserve caller credentials, fallback to pending NFC pairing if unsupplied
    Uint8List? effectiveNfcCommitment = nfcCommitment;
    Uint8List? effectivePairingSecret = pairingSecret;
    if (effectiveNfcCommitment == null && effectivePairingSecret == null) {
      final pendingNfc = _consumePendingNfcPairing(
        connectionSession.remoteDeviceId,
      );
      effectiveNfcCommitment = pendingNfc?.nfcCommitment;
      effectivePairingSecret = pendingNfc?.pairingSecret;
    }

    final future = _doSecureOutboundConnection(
      connectionSession,
      nfcCommitment: effectiveNfcCommitment,
      pairingSecret: effectivePairingSecret,
      timeout: timeout,
    );
    _inFlightOutboundSecuring[connectionSession.sessionId] = future;
    try {
      return await future;
    } finally {
      _inFlightOutboundSecuring.remove(connectionSession.sessionId);
    }
  }

  Future<SecureSessionImpl> _doSecureOutboundConnection(
    ConnectionSession connectionSession, {
    Uint8List? nfcCommitment,
    Uint8List? pairingSecret,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final localKp = await getOrInitializeLocalKeypair();
    final sessionIdBytes = _parseHexOrUuidToBytes(connectionSession.sessionId);
    final remoteDevIdBytes = _parseHexOrUuidToBytes(
      connectionSession.remoteDeviceId,
    );

    AppLogger.info(
      'SecureSessionManager',
      'Starting 3-way authenticated key exchange as Initiator for session ${connectionSession.sessionId}',
    );

    // 1. Generate ephemeral X25519 keypair and 32-byte nonce
    final ephPairA = await cryptoService.generateEphemeralX25519Keypair();
    final ephPubA = await cryptoService.extractX25519PublicKey(ephPairA);
    final nonceA = _generateRandomBytes(32);

    // 2. Construct and sign M_init (168 bytes)
    final mInit = AuthInitPayload.constructSigningMessage(
      sessionId: sessionIdBytes,
      initiatorDeviceId: localIdentity.deviceId,
      responderDeviceId: remoteDevIdBytes,
      initiatorEphemeralPubKey: ephPubA,
      initiatorNonce: nonceA,
      initiatorIdentityPubKey: localKp.publicKey,
    );

    final sigA = await cryptoService.signEd25519(
      message: mInit,
      privateKeySeed: localKp.privateKeySeed!,
    );

    // 3. Send AuthInitPayload (180 bytes)
    final initPayload = AuthInitPayload(
      sessionId: sessionIdBytes,
      ephemeralPubKey: ephPubA,
      nonce: nonceA,
      identityPubKey: localKp.publicKey,
      signature: sigA,
    );

    final initPacket = VayuPacket(
      packetType: PacketType.authExchange,
      packetId: 1,
      sourceDeviceId: localIdentity.deviceId,
      destinationDeviceId: remoteDevIdBytes,
      payload: initPayload.toBytes(),
    );

    await connectionSession.sendPacket(initPacket);

    // 4. Await AuthResponsePayload (212 bytes) from Responder
    final responsePacket = await connectionSession.incomingPackets
        .where((p) => p.packetType == PacketType.authExchange)
        .first
        .timeout(
          timeout,
          onTimeout: () =>
              throw SecurityError('Handshake timed out awaiting AuthResponse'),
        );

    final responsePayload = AuthResponsePayload.fromBytes(
      responsePacket.payload,
    );

    // 5. Verify Responder's Ed25519 signature over M_resp (204 bytes)
    final initChallengeHash =
        HandshakeTranscriptHelper.computeInitiatorChallengeHash(
          mInit: mInit,
          sigA: sigA,
        );

    final mResp = AuthResponsePayload.constructSigningMessage(
      sessionId: sessionIdBytes,
      responderDeviceId: remoteDevIdBytes,
      initiatorDeviceId: localIdentity.deviceId,
      responderEphemeralPubKey: responsePayload.ephemeralPubKey,
      responderNonce: responsePayload.nonce,
      responderIdentityPubKey: responsePayload.identityPubKey,
      initiatorChallengeHash: initChallengeHash,
    );

    final isSigValid = await cryptoService.verifyEd25519(
      message: mResp,
      signature: responsePayload.signature,
      publicKey: responsePayload.identityPubKey,
    );

    if (!isSigValid) {
      throw SecurityError(
        'Invalid responder Ed25519 signature on session ${connectionSession.sessionId}',
      );
    }

    final pendingNfc = _consumePendingNfcPairing(
      connectionSession.remoteDeviceId,
    );
    final effectiveNfcCommitment = nfcCommitment ?? pendingNfc?.nfcCommitment;
    final effectivePairingSecret = pairingSecret ?? pendingNfc?.pairingSecret;

    // 6. Evaluate Responder's identity in TrustStore (detects TOFU / key conflict)
    final trustLevel = await trustStore.evaluatePeer(
      deviceIdHex: connectionSession.remoteDeviceId,
      presentedIdentityPubKey: responsePayload.identityPubKey,
      nfcCommitment: effectiveNfcCommitment,
      pairingSecret: effectivePairingSecret,
    );

    // 7. Compute X25519 ECDH Shared Secret
    final sharedSecret = await cryptoService.computeSharedSecret(
      localKeyPair: ephPairA,
      remotePublicKeyBytes: responsePayload.ephemeralPubKey,
    );

    // 8. Compute H_transcript (500 bytes -> 32 bytes)
    final transcriptHash = HandshakeTranscriptHelper.computeTranscriptHash(
      mInit: mInit,
      sigA: sigA,
      mResp: mResp,
      sigB: responsePayload.signature,
    );

    // 9. Derive Session Keys via HKDF-SHA256
    final derivedKeys = await cryptoService.deriveSessionKeys(
      sharedSecret: sharedSecret,
      initiatorNonce: nonceA,
      responderNonce: responsePayload.nonce,
      sessionId: sessionIdBytes,
      transcriptHash: transcriptHash,
    );

    // Wipe raw shared secret
    CryptoService.secureWipe(sharedSecret);

    // 10. Verify Responder's Confirmation MAC
    final expectedRespMac = await cryptoService.computeConfirmMac(
      confirmKey: derivedKeys.confirmKey,
      label: 'resp-confirm:',
      transcriptHash: transcriptHash,
    );

    if (!_bytesEqual(expectedRespMac, responsePayload.confirmMac)) {
      throw SecurityError(
        'Responder confirmation MAC mismatch on session ${connectionSession.sessionId}',
      );
    }

    // 11. Compute and send Initiator's Confirmation MAC (AuthConfirmPayload: 49 bytes)
    final initConfirmMac = await cryptoService.computeConfirmMac(
      confirmKey: derivedKeys.confirmKey,
      label: 'init-confirm:',
      transcriptHash: transcriptHash,
    );

    final confirmPayload = AuthConfirmPayload(
      sessionId: sessionIdBytes,
      confirmMac: initConfirmMac,
    );

    final confirmPacket = VayuPacket(
      packetType: PacketType.authExchange,
      packetId: 2,
      sourceDeviceId: localIdentity.deviceId,
      destinationDeviceId: remoteDevIdBytes,
      payload: confirmPayload.toBytes(),
    );

    await connectionSession.sendPacket(confirmPacket);

    // 12. Transition state to SessionState.secured
    connectionSession.updateState(SessionState.secured);

    final sas = ShortAuthenticationString.fromKey(derivedKeys.sasKey);

    final secureSession = SecureSessionImpl(
      connectionSession: connectionSession,
      cryptoService: cryptoService,
      derivedKeys: derivedKeys,
      sas: sas,
      localIdentityPubKey: localKp.publicKey,
      remoteIdentityPubKey: responsePayload.identityPubKey,
      isInitiator: true,
      initialTrustLevel: trustLevel,
    );

    _registerSession(secureSession);
    return secureSession;
  }

  /// Handles incoming [AuthInitPayload] from an inbound connection and completes the 3-way handshake.
  Future<SecureSessionImpl> handleInboundAuthInit(
    ConnectionSession connectionSession,
    AuthInitPayload initPayload, {
    Uint8List? nfcCommitment,
    Uint8List? pairingSecret,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final localKp = await getOrInitializeLocalKeypair();
    final sessionIdBytes = initPayload.sessionId;
    final remoteDevIdBytes = _parseHexOrUuidToBytes(
      connectionSession.remoteDeviceId,
    );

    AppLogger.info(
      'SecureSessionManager',
      'Handling 3-way authenticated key exchange as Responder for session ${connectionSession.sessionId}',
    );

    // 1. Verify Initiator's Ed25519 signature over M_init (168 bytes)
    final mInit = AuthInitPayload.constructSigningMessage(
      protocolVersion: initPayload.protocolVersion,
      cipherSuite: initPayload.cipherSuite,
      sessionId: sessionIdBytes,
      initiatorDeviceId: remoteDevIdBytes,
      responderDeviceId: localIdentity.deviceId,
      initiatorEphemeralPubKey: initPayload.ephemeralPubKey,
      initiatorNonce: initPayload.nonce,
      initiatorIdentityPubKey: initPayload.identityPubKey,
    );

    final isSigValid = await cryptoService.verifyEd25519(
      message: mInit,
      signature: initPayload.signature,
      publicKey: initPayload.identityPubKey,
    );

    if (!isSigValid) {
      throw SecurityError(
        'Invalid initiator Ed25519 signature on session ${connectionSession.sessionId}',
      );
    }

    final pendingNfc = _consumePendingNfcPairing(
      connectionSession.remoteDeviceId,
    );
    final effectiveNfcCommitment = nfcCommitment ?? pendingNfc?.nfcCommitment;
    final effectivePairingSecret = pairingSecret ?? pendingNfc?.pairingSecret;

    // 2. Evaluate Initiator's identity in TrustStore (detects TOFU / key conflict)
    final trustLevel = await trustStore.evaluatePeer(
      deviceIdHex: connectionSession.remoteDeviceId,
      presentedIdentityPubKey: initPayload.identityPubKey,
      nfcCommitment: effectiveNfcCommitment,
      pairingSecret: effectivePairingSecret,
    );

    // 3. Generate Responder's ephemeral X25519 keypair and nonce
    final ephPairB = await cryptoService.generateEphemeralX25519Keypair();
    final ephPubB = await cryptoService.extractX25519PublicKey(ephPairB);
    final nonceB = _generateRandomBytes(32);

    // 4. Compute X25519 ECDH Shared Secret
    final sharedSecret = await cryptoService.computeSharedSecret(
      localKeyPair: ephPairB,
      remotePublicKeyBytes: initPayload.ephemeralPubKey,
    );

    // 5. Construct and sign M_resp (204 bytes)
    final initChallengeHash =
        HandshakeTranscriptHelper.computeInitiatorChallengeHash(
          mInit: mInit,
          sigA: initPayload.signature,
        );

    final mResp = AuthResponsePayload.constructSigningMessage(
      protocolVersion: initPayload.protocolVersion,
      cipherSuite: initPayload.cipherSuite,
      sessionId: sessionIdBytes,
      responderDeviceId: localIdentity.deviceId,
      initiatorDeviceId: remoteDevIdBytes,
      responderEphemeralPubKey: ephPubB,
      responderNonce: nonceB,
      responderIdentityPubKey: localKp.publicKey,
      initiatorChallengeHash: initChallengeHash,
    );

    final sigB = await cryptoService.signEd25519(
      message: mResp,
      privateKeySeed: localKp.privateKeySeed!,
    );

    // 6. Compute H_transcript (500 bytes -> 32 bytes)
    final transcriptHash = HandshakeTranscriptHelper.computeTranscriptHash(
      mInit: mInit,
      sigA: initPayload.signature,
      mResp: mResp,
      sigB: sigB,
    );

    // 7. Derive Session Keys via HKDF-SHA256
    final derivedKeys = await cryptoService.deriveSessionKeys(
      sharedSecret: sharedSecret,
      initiatorNonce: initPayload.nonce,
      responderNonce: nonceB,
      sessionId: sessionIdBytes,
      transcriptHash: transcriptHash,
    );

    CryptoService.secureWipe(sharedSecret);

    // 8. Compute Responder's Confirmation MAC
    final respConfirmMac = await cryptoService.computeConfirmMac(
      confirmKey: derivedKeys.confirmKey,
      label: 'resp-confirm:',
      transcriptHash: transcriptHash,
    );

    // 9. Send AuthResponsePayload (212 bytes)
    final responsePayload = AuthResponsePayload(
      protocolVersion: initPayload.protocolVersion,
      cipherSuite: initPayload.cipherSuite,
      sessionId: sessionIdBytes,
      ephemeralPubKey: ephPubB,
      nonce: nonceB,
      identityPubKey: localKp.publicKey,
      signature: sigB,
      confirmMac: respConfirmMac,
    );

    final responsePacket = VayuPacket(
      packetType: PacketType.authExchange,
      packetId: 1,
      sourceDeviceId: localIdentity.deviceId,
      destinationDeviceId: remoteDevIdBytes,
      payload: responsePayload.toBytes(),
    );

    // The initiator becomes secured as soon as it sends AuthConfirm and may send
    // application data right behind it. Hold those packets until our session exists.
    const maxEarlyPackets = 256;
    final earlyPackets = <VayuPacket>[];
    final earlySubscription = connectionSession.incomingPackets.listen((p) {
      if (!SecureSessionImpl.isControlPacket(p) &&
          earlyPackets.length < maxEarlyPackets) {
        earlyPackets.add(p);
      }
    }, onError: (_) {});

    final VayuPacket confirmPacket;
    try {
      await connectionSession.sendPacket(responsePacket);

      // 10. Await AuthConfirmPayload (49 bytes) from Initiator
      confirmPacket = await connectionSession.incomingPackets
          .where(
            (p) =>
                p.packetType == PacketType.authExchange &&
                p.payload.length == AuthConfirmPayload.payloadSize,
          )
          .first
          .timeout(
            timeout,
            onTimeout: () =>
                throw SecurityError('Handshake timed out awaiting AuthConfirm'),
          );
    } catch (_) {
      await earlySubscription.cancel();
      rethrow;
    }

    final confirmPayload = AuthConfirmPayload.fromBytes(confirmPacket.payload);

    // 11. Verify Initiator's Confirmation MAC
    final expectedInitMac = await cryptoService.computeConfirmMac(
      confirmKey: derivedKeys.confirmKey,
      label: 'init-confirm:',
      transcriptHash: transcriptHash,
    );

    if (!_bytesEqual(expectedInitMac, confirmPayload.confirmMac)) {
      await earlySubscription.cancel();
      throw SecurityError(
        'Initiator confirmation MAC mismatch on session ${connectionSession.sessionId}',
      );
    }

    // 12. Transition state to SessionState.secured
    connectionSession.updateState(SessionState.secured);

    final sas = ShortAuthenticationString.fromKey(derivedKeys.sasKey);

    final secureSession = SecureSessionImpl(
      connectionSession: connectionSession,
      cryptoService: cryptoService,
      derivedKeys: derivedKeys,
      sas: sas,
      localIdentityPubKey: localKp.publicKey,
      remoteIdentityPubKey: initPayload.identityPubKey,
      isInitiator: false,
      initialTrustLevel: trustLevel,
    );

    // The session's own pipeline is subscribed now; hand over what arrived early.
    await earlySubscription.cancel();
    secureSession.replayEarlyPackets(earlyPackets);

    _registerSession(secureSession);
    return secureSession;
  }

  /// Registers an out-of-band NFC pairing payload for mutual cryptographic authentication.
  void registerPendingNfcPairing(PairingPayload payload) {
    if (payload.ed25519PubKeyBytes != null &&
        payload.nfcCommitmentBytes != null) {
      final clean = payload.deviceIdHex.toLowerCase();
      _pendingNfcPairings[clean] = PendingNfcPairing(
        deviceIdHex: clean,
        ed25519PubKey: payload.ed25519PubKeyBytes!,
        nfcCommitment: payload.nfcCommitmentBytes!,
        pairingSecret: payload.pairingSecretBytes,
        receivedAt: DateTime.now(),
      );
      AppLogger.info(
        'SecureSessionManager',
        'Registered pending NFC pairing commitment for device $clean',
      );
    }
  }

  PendingNfcPairing? _consumePendingNfcPairing(String remoteDeviceId) {
    final clean = remoteDeviceId.replaceAll('-', '').toLowerCase();
    final pending = _pendingNfcPairings.remove(clean);
    if (pending != null && !pending.isExpired) {
      return pending;
    }
    return null;
  }

  void _registerSession(SecureSessionImpl session) {
    _sessions[session.sessionId] = session;
    _sessionController.add(session);

    // Wire automatic in-band rekey trigger
    session.onRekeyRequested = (s) {
      initiateRekey(s.sessionId);
    };

    // Attach in-band rekey packet listener
    _attachRekeyListener(session);

    AppLogger.info(
      'SecureSessionManager',
      'Session ${session.sessionId} secured! (SAS: ${session.sas.numeric}, Trust: ${session.trustLevel}, Epoch: ${session.currentEpoch})',
    );
  }

  void _attachRekeyListener(SecureSessionImpl session) {
    _rekeySubscriptions[session.sessionId]?.cancel();
    final sub = session.connectionSession.incomingPackets.listen((packet) {
      if (packet.packetType == PacketType.authExchange &&
          packet.payload.isNotEmpty) {
        final subtype = packet.payload[0];
        if (subtype == AuthExchangeSubtype.rekeyInit.code) {
          try {
            final rekeyInit = RekeyInitPayload.fromBytes(packet.payload);
            _handleIncomingRekeyInit(session, rekeyInit);
          } catch (e) {
            AppLogger.warning(
              'SecureSessionManager',
              'Failed to process incoming RekeyInit on session ${session.sessionId}: $e',
            );
          }
        }
      }
    });
    _rekeySubscriptions[session.sessionId] = sub;
  }

  StreamSubscription<ConnectionSession>? _sessionSubscription;

  /// Attaches to [ConnectionManager], automatically negotiating 3-way authenticated Diffie-Hellman
  /// key exchanges for both outbound (initiator) and inbound (responder) connection sessions.
  void attachToConnectionManager(ConnectionManager connectionManager) {
    _sessionSubscription?.cancel();
    _sessionSubscription = connectionManager.onSessionEstablished.listen(
      (session) {
        _handleSessionEstablished(session);
      },
      onError: (e) {
        AppLogger.warning(
          'SecureSessionManager',
          'Error on ConnectionManager session established stream: $e',
        );
      },
    );
  }

  Future<void> _handleSessionEstablished(ConnectionSession session) async {
    if (session.isInitiator) {
      // Yield to allow synchronous/immediate caller elevation (e.g. SmartTransportSelectorImpl
      // or explicit secureOutboundConnection calls) to take precedence with custom credentials/timeouts.
      await Future<void>.delayed(Duration.zero);
      if (_sessions[session.sessionId]?.isEstablished == true ||
          _inFlightOutboundSecuring.containsKey(session.sessionId)) {
        return;
      }
      try {
        await secureOutboundConnection(session);
      } catch (e) {
        AppLogger.warning(
          'SecureSessionManager',
          'Failed to auto-secure outbound session ${session.sessionId}: $e',
        );
      }
    } else {
      final pendingNfc = _consumePendingNfcPairing(session.remoteDeviceId);
      final nfcCommitment = pendingNfc?.nfcCommitment;
      final pairingSecret = pendingNfc?.pairingSecret;

      // Responder awaits AuthInitPayload from Initiator
      try {
        final packet = await session.incomingPackets
            .where((p) => p.packetType == PacketType.authExchange)
            .first
            .timeout(const Duration(seconds: 10));
        final initPayload = AuthInitPayload.fromBytes(packet.payload);
        await handleInboundAuthInit(
          session,
          initPayload,
          nfcCommitment: nfcCommitment,
          pairingSecret: pairingSecret,
        );
      } catch (e) {
        AppLogger.warning(
          'SecureSessionManager',
          'Failed to handle inbound auth init on session ${session.sessionId}: $e',
        );
        // A peer that did not authenticate gets nothing from this link, and
        // leaving it open would hold one of the few unauthenticated slots.
        if (_sessions[session.sessionId]?.isEstablished != true) {
          await session.close(reason: 'authentication_failed');
        }
      }
    }
  }

  /// Initiates an in-band Rekey-v1 exchange as Rekey Initiator for [sessionId].
  Future<void> initiateRekey(
    String sessionId, {
    Duration timeout = const Duration(seconds: 3),
    int maxRetries = 2,
  }) async {
    final session = _sessions[sessionId];
    if (session == null || !session.isEstablished) {
      AppLogger.warning(
        'SecureSessionManager',
        'Cannot initiate rekey: session $sessionId is not active',
      );
      return;
    }

    if (session.currentEpoch >= 255) {
      AppLogger.warning(
        'SecureSessionManager',
        'Maximum key epochs (255) reached on session $sessionId; session must be renegotiated',
      );
      await session.terminate();
      return;
    }

    session.rekeyInProgress = true;
    final targetEpoch = session.currentEpoch + 1;
    final localKp = await getOrInitializeLocalKeypair();
    final sessionIdBytes = _parseHexOrUuidToBytes(session.sessionId);
    final remoteDevIdBytes = _parseHexOrUuidToBytes(session.remoteDeviceId);

    AppLogger.info(
      'SecureSessionManager',
      'Initiating in-band rekey for session $sessionId to target epoch $targetEpoch',
    );

    int attempt = 0;
    while (attempt <= maxRetries &&
        session.isEstablished &&
        session.rekeyInProgress) {
      attempt++;
      try {
        // 1. Generate fresh ephemeral X25519 keypair and 32B nonce
        final ephPairA = await cryptoService.generateEphemeralX25519Keypair();
        final ephPubA = await cryptoService.extractX25519PublicKey(ephPairA);
        final nonceA = _generateRandomBytes(32);

        // 2. Compute PrevEpochMac using activeConfirmKey
        final prevEpochMac = await cryptoService.computeRekeyPrevEpochMac(
          prevConfirmKey: session.activeConfirmKey,
          sessionId: sessionIdBytes,
          targetEpoch: targetEpoch,
          ephemeralPubKey: ephPubA,
          nonce: nonceA,
        );

        // 3. Construct and sign M_rekey_init (169 bytes)
        final mRekeyInit = RekeyInitPayload.constructSigningMessage(
          targetEpoch: targetEpoch,
          sessionId: sessionIdBytes,
          initiatorDeviceId: localIdentity.deviceId,
          responderDeviceId: remoteDevIdBytes,
          initiatorEphemeralPubKey: ephPubA,
          initiatorNonce: nonceA,
          initiatorIdentityPubKey: localKp.publicKey,
        );

        final sigA = await cryptoService.signEd25519(
          message: mRekeyInit,
          privateKeySeed: localKp.privateKeySeed!,
        );

        // 4. Send RekeyInitPayload (180 bytes)
        final initPayload = RekeyInitPayload(
          targetEpoch: targetEpoch,
          sessionId: sessionIdBytes,
          ephemeralPubKey: ephPubA,
          nonce: nonceA,
          prevEpochMac: prevEpochMac,
          signature: sigA,
        );

        final initPacket = VayuPacket(
          packetType: PacketType.authExchange,
          packetId: 1000 + targetEpoch,
          sourceDeviceId: localIdentity.deviceId,
          destinationDeviceId: remoteDevIdBytes,
          payload: initPayload.toBytes(),
        );

        await session.connectionSession.sendPacket(initPacket);

        // 5. Await RekeyResponsePayload (212 bytes) or epoch advancement (if yielded in simultaneous collision)
        final respPacket = await session.connectionSession.incomingPackets
            .where(
              (p) =>
                  (p.packetType == PacketType.authExchange &&
                      p.payload.isNotEmpty &&
                      p.payload[0] == AuthExchangeSubtype.rekeyResponse.code) ||
                  session.currentEpoch >= targetEpoch,
            )
            .first
            .timeout(timeout);

        if (session.currentEpoch >= targetEpoch) {
          AppLogger.info(
            'SecureSessionManager',
            'Session $sessionId already advanced to epoch $targetEpoch via simultaneous collision tie-breaker.',
          );
          session.rekeyInProgress = false;
          return;
        }

        final respPayload = RekeyResponsePayload.fromBytes(respPacket.payload);
        if (respPayload.targetEpoch != targetEpoch ||
            !_bytesEqual(respPayload.sessionId, sessionIdBytes)) {
          throw SecurityError(
            'Mismatched targetEpoch or sessionId in RekeyResponse',
          );
        }

        // 6. Verify Initiator Challenge Hash
        final expectedChallengeHash =
            RekeyTranscriptHelper.computeInitiatorChallengeHash(
              mRekeyInit: mRekeyInit,
              sigInit: sigA,
            );
        if (!_bytesEqual(
          expectedChallengeHash,
          respPayload.initChallengeHash,
        )) {
          throw SecurityError(
            'Initiator challenge hash mismatch in RekeyResponse',
          );
        }

        // 7. Verify Responder's Ed25519 signature over M_rekey_resp
        final mRekeyResp = RekeyResponsePayload.constructSigningMessage(
          targetEpoch: targetEpoch,
          sessionId: sessionIdBytes,
          responderDeviceId: remoteDevIdBytes,
          initiatorDeviceId: localIdentity.deviceId,
          responderEphemeralPubKey: respPayload.ephemeralPubKey,
          responderNonce: respPayload.nonce,
          responderIdentityPubKey: session.remoteIdentityPubKey,
          initiatorChallengeHash: expectedChallengeHash,
        );

        final isSigValid = await cryptoService.verifyEd25519(
          message: mRekeyResp,
          signature: respPayload.signature,
          publicKey: session.remoteIdentityPubKey,
        );
        if (!isSigValid) {
          throw SecurityError(
            'Invalid responder Ed25519 signature on RekeyResponse',
          );
        }

        // 8. Compute Shared Secret & Derive Epoch E+1 Session Keys
        final sharedSecret = await cryptoService.computeSharedSecret(
          localKeyPair: ephPairA,
          remotePublicKeyBytes: respPayload.ephemeralPubKey,
        );

        final transcriptHash = RekeyTranscriptHelper.computeTranscriptHash(
          mRekeyInit: mRekeyInit,
          sigInit: sigA,
          mRekeyResp: mRekeyResp,
          sigResp: respPayload.signature,
        );

        final derivedRekeyKeys = await cryptoService.deriveRekeySessionKeys(
          sharedSecret: sharedSecret,
          prevConfirmKey: session.activeConfirmKey,
          initiatorNonce: nonceA,
          responderNonce: respPayload.nonce,
          sessionId: sessionIdBytes,
          targetEpoch: targetEpoch,
          transcriptHash: transcriptHash,
        );

        CryptoService.secureWipe(sharedSecret);

        // 9. Verify Responder Confirm MAC
        final expectedRespMac = await cryptoService.computeConfirmMac(
          confirmKey: derivedRekeyKeys.confirmKey,
          label: 'rekey-resp-confirm:',
          transcriptHash: transcriptHash,
        );
        if (!_bytesEqual(expectedRespMac, respPayload.confirmMac)) {
          throw SecurityError('Responder confirm MAC mismatch on rekey');
        }

        // 10. Send RekeyConfirmPayload (51 bytes)
        final initConfirmMac = await cryptoService.computeConfirmMac(
          confirmKey: derivedRekeyKeys.confirmKey,
          label: 'rekey-init-confirm:',
          transcriptHash: transcriptHash,
        );

        final confirmPayload = RekeyConfirmPayload(
          targetEpoch: targetEpoch,
          sessionId: sessionIdBytes,
          confirmMac: initConfirmMac,
        );

        final confirmPacket = VayuPacket(
          packetType: PacketType.authExchange,
          packetId: 2000 + targetEpoch,
          sourceDeviceId: localIdentity.deviceId,
          destinationDeviceId: remoteDevIdBytes,
          payload: confirmPayload.toBytes(),
        );

        await session.connectionSession.sendPacket(confirmPacket);

        // 11. Apply New Epoch to Active Session
        session.applyNewEpoch(derivedRekeyKeys, targetEpoch);
        AppLogger.info(
          'SecureSessionManager',
          'Successfully transitioned session $sessionId to epoch $targetEpoch',
        );
        return;
      } on TimeoutException {
        AppLogger.warning(
          'SecureSessionManager',
          'Rekey attempt $attempt timed out for session $sessionId',
        );
      } catch (e) {
        AppLogger.error(
          'SecureSessionManager',
          'Rekey attempt $attempt failed with error: $e',
        );
        break;
      }
    }

    session.rekeyInProgress = false;
  }

  Future<void> _handleIncomingRekeyInit(
    SecureSessionImpl session,
    RekeyInitPayload initPayload, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final sessionIdBytes = _parseHexOrUuidToBytes(session.sessionId);
    final remoteDevIdBytes = _parseHexOrUuidToBytes(session.remoteDeviceId);

    if (!_bytesEqual(initPayload.sessionId, sessionIdBytes)) {
      AppLogger.warning(
        'SecureSessionManager',
        'Ignoring RekeyInit with mismatched sessionId',
      );
      return;
    }

    final targetEpoch = initPayload.targetEpoch;
    if (targetEpoch != session.currentEpoch + 1) {
      AppLogger.warning(
        'SecureSessionManager',
        'Ignoring RekeyInit with invalid targetEpoch $targetEpoch (current: ${session.currentEpoch})',
      );
      return;
    }

    // Simultaneous Rekey Collision Tie-Breaker:
    if (session.rekeyInProgress) {
      final localDevIdClean = localIdentity.idHex.toLowerCase();
      final remoteDevIdClean = session.remoteDeviceId
          .replaceAll('-', '')
          .toLowerCase();
      if (localDevIdClean.compareTo(remoteDevIdClean) > 0) {
        // Local device ID is higher: Local wins initiator role!
        AppLogger.info(
          'SecureSessionManager',
          'Simultaneous rekey collision: local device ID is higher; ignoring remote RekeyInit',
        );
        return;
      } else {
        // Local device ID is lower: Local yields!
        AppLogger.info(
          'SecureSessionManager',
          'Simultaneous rekey collision: local device ID is lower; yielding to remote RekeyInit',
        );
        session.rekeyInProgress = false;
      }
    }

    try {
      // 1. Verify PrevEpochMac using activeConfirmKey
      final expectedPrevMac = await cryptoService.computeRekeyPrevEpochMac(
        prevConfirmKey: session.activeConfirmKey,
        sessionId: sessionIdBytes,
        targetEpoch: targetEpoch,
        ephemeralPubKey: initPayload.ephemeralPubKey,
        nonce: initPayload.nonce,
      );

      if (!_bytesEqual(expectedPrevMac, initPayload.prevEpochMac)) {
        AppLogger.warning(
          'SecureSessionManager',
          'PrevEpochMac verification failed on RekeyInit for session ${session.sessionId}',
        );
        return;
      }

      // 2. Verify Initiator's Ed25519 signature on M_rekey_init
      final localKp = await getOrInitializeLocalKeypair();
      final mRekeyInit = RekeyInitPayload.constructSigningMessage(
        targetEpoch: targetEpoch,
        sessionId: sessionIdBytes,
        initiatorDeviceId: remoteDevIdBytes,
        responderDeviceId: localIdentity.deviceId,
        initiatorEphemeralPubKey: initPayload.ephemeralPubKey,
        initiatorNonce: initPayload.nonce,
        initiatorIdentityPubKey: session.remoteIdentityPubKey,
      );

      final isSigValid = await cryptoService.verifyEd25519(
        message: mRekeyInit,
        signature: initPayload.signature,
        publicKey: session.remoteIdentityPubKey,
      );

      if (!isSigValid) {
        AppLogger.warning(
          'SecureSessionManager',
          'Initiator Ed25519 signature verification failed on RekeyInit',
        );
        return;
      }

      // 3. Generate Responder ephemeral X25519 keypair and 32B nonce
      final ephPairB = await cryptoService.generateEphemeralX25519Keypair();
      final ephPubB = await cryptoService.extractX25519PublicKey(ephPairB);
      final nonceB = _generateRandomBytes(32);

      // 4. Compute Shared Secret & Derive Epoch E+1 Session Keys
      final sharedSecret = await cryptoService.computeSharedSecret(
        localKeyPair: ephPairB,
        remotePublicKeyBytes: initPayload.ephemeralPubKey,
      );

      final initChallengeHash =
          RekeyTranscriptHelper.computeInitiatorChallengeHash(
            mRekeyInit: mRekeyInit,
            sigInit: initPayload.signature,
          );

      final mRekeyResp = RekeyResponsePayload.constructSigningMessage(
        targetEpoch: targetEpoch,
        sessionId: sessionIdBytes,
        responderDeviceId: localIdentity.deviceId,
        initiatorDeviceId: remoteDevIdBytes,
        responderEphemeralPubKey: ephPubB,
        responderNonce: nonceB,
        responderIdentityPubKey: localKp.publicKey,
        initiatorChallengeHash: initChallengeHash,
      );

      final sigB = await cryptoService.signEd25519(
        message: mRekeyResp,
        privateKeySeed: localKp.privateKeySeed!,
      );

      final transcriptHash = RekeyTranscriptHelper.computeTranscriptHash(
        mRekeyInit: mRekeyInit,
        sigInit: initPayload.signature,
        mRekeyResp: mRekeyResp,
        sigResp: sigB,
      );

      final derivedRekeyKeys = await cryptoService.deriveRekeySessionKeys(
        sharedSecret: sharedSecret,
        prevConfirmKey: session.activeConfirmKey,
        initiatorNonce: initPayload.nonce,
        responderNonce: nonceB,
        sessionId: sessionIdBytes,
        targetEpoch: targetEpoch,
        transcriptHash: transcriptHash,
      );

      CryptoService.secureWipe(sharedSecret);

      // 5. Compute Responder Confirm MAC
      final respConfirmMac = await cryptoService.computeConfirmMac(
        confirmKey: derivedRekeyKeys.confirmKey,
        label: 'rekey-resp-confirm:',
        transcriptHash: transcriptHash,
      );

      // 6. Send RekeyResponsePayload (212 bytes)
      final respPayload = RekeyResponsePayload(
        targetEpoch: targetEpoch,
        sessionId: sessionIdBytes,
        ephemeralPubKey: ephPubB,
        nonce: nonceB,
        initChallengeHash: initChallengeHash,
        signature: sigB,
        confirmMac: respConfirmMac,
      );

      final respPacket = VayuPacket(
        packetType: PacketType.authExchange,
        packetId: 1000 + targetEpoch,
        sourceDeviceId: localIdentity.deviceId,
        destinationDeviceId: remoteDevIdBytes,
        payload: respPayload.toBytes(),
      );

      await session.connectionSession.sendPacket(respPacket);

      // 7. Await RekeyConfirmPayload (51 bytes) from Initiator
      final confirmPacket = await session.connectionSession.incomingPackets
          .where(
            (p) =>
                p.packetType == PacketType.authExchange &&
                p.payload.isNotEmpty &&
                p.payload[0] == AuthExchangeSubtype.rekeyConfirm.code,
          )
          .first
          .timeout(timeout);

      final confirmPayload = RekeyConfirmPayload.fromBytes(
        confirmPacket.payload,
      );
      if (confirmPayload.targetEpoch != targetEpoch ||
          !_bytesEqual(confirmPayload.sessionId, sessionIdBytes)) {
        throw SecurityError(
          'Mismatched targetEpoch or sessionId in RekeyConfirm',
        );
      }

      // 8. Verify Initiator Confirm MAC
      final expectedInitMac = await cryptoService.computeConfirmMac(
        confirmKey: derivedRekeyKeys.confirmKey,
        label: 'rekey-init-confirm:',
        transcriptHash: transcriptHash,
      );

      if (!_bytesEqual(expectedInitMac, confirmPayload.confirmMac)) {
        throw SecurityError('Initiator confirmation MAC mismatch on rekey');
      }

      // 9. Apply New Epoch to Active Session
      session.applyNewEpoch(derivedRekeyKeys, targetEpoch);
      AppLogger.info(
        'SecureSessionManager',
        'Responder successfully transitioned session ${session.sessionId} to epoch $targetEpoch',
      );
    } catch (e) {
      AppLogger.error(
        'SecureSessionManager',
        'Failed to handle incoming RekeyInit: $e',
      );
    }
  }

  /// Promotes a session's peer to [TrustLevel.sasVerified] after out-of-band SAS code confirmation.
  Future<void> confirmSasVerification(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('Cannot confirm SAS: session $sessionId not found');
    }
    await trustStore.promoteToSasVerified(
      session.remoteDeviceId,
      session.remoteIdentityPubKey,
    );
    session.updateTrustLevel(TrustLevel.sasVerified);
    _sessionController.add(session);
    AppLogger.info(
      'SecureSessionManager',
      'Session $sessionId upgraded to SAS Verified',
    );
  }

  Future<void> dispose() async {
    await _sessionSubscription?.cancel();
    _sessionSubscription = null;
    for (final sub in _rekeySubscriptions.values) {
      await sub.cancel();
    }
    _rekeySubscriptions.clear();
    for (final session in _sessions.values) {
      await session.terminate();
    }
    _sessions.clear();
    await _sessionController.close();
  }

  static Uint8List _generateRandomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  static Uint8List _parseHexOrUuidToBytes(String str) {
    final clean = str.replaceAll('-', '').toLowerCase();
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
