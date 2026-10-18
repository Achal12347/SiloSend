import 'dart:async';
import 'dart:typed_data';

import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/contracts/security_contract.dart';
import 'package:vayu/core/errors/app_error.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/replay_protection_filter.dart';
import 'package:vayu/core/security/short_authentication_string.dart';
import 'package:vayu/domain/protocol/packet_type.dart';
import 'package:vayu/domain/protocol/vayu_packet.dart';
import 'package:vayu/domain/security/encrypted_envelope.dart';
import 'package:vayu/domain/security/trust_level.dart';

/// Cryptographic keys and replay filter for a specific key epoch.
class KeyEpochMaterial {
  final int epoch;
  final Uint8List txKey;
  final Uint8List rxKey;
  final Uint8List txSalt;
  final Uint8List rxSalt;
  final Uint8List confirmKey;
  final ReplayProtectionFilter replayFilter;

  KeyEpochMaterial({
    required this.epoch,
    required this.txKey,
    required this.rxKey,
    required this.txSalt,
    required this.rxSalt,
    required this.confirmKey,
    required this.replayFilter,
  });

  void wipe() {
    CryptoService.secureWipe(txKey);
    CryptoService.secureWipe(rxKey);
    CryptoService.secureWipe(txSalt);
    CryptoService.secureWipe(rxSalt);
    CryptoService.secureWipe(confirmKey);
  }
}

/// Concrete implementation of [SecureSession] managing authenticated, forward-secure,
/// AEAD-encrypted communication over an active [ConnectionSession] with Rekey-v1 support.
class SecureSessionImpl implements SecureSession {
  /// Conservative application engineering threshold for AES-GCM single-key invocations.
  static const int maxPacketsPerKey =
      0x100000000; // 2^32 (4,294,967,296 packets)

  /// Default application rekey threshold triggering in-band rekeying.
  static const int defaultRekeyThreshold =
      0x10000000; // 2^28 (268,435,456 packets)

  /// Default drain period for in-flight packets of the previous epoch.
  static const Duration defaultGraceDrainDuration = Duration(seconds: 5);

  final ConnectionSession connectionSession;
  final CryptoService cryptoService;
  final DerivedSessionKeys derivedKeys;
  final ShortAuthenticationString sas;
  final Uint8List localIdentityPubKey;
  final Uint8List remoteIdentityPubKey;
  final bool isInitiator;

  TrustLevel _trustLevel;
  int _txSequence = 0;
  int rekeyThreshold;
  Duration graceDrainDuration;

  late KeyEpochMaterial _activeEpoch;
  KeyEpochMaterial? _retainedPreviousEpoch;
  Timer? _gracePeriodTimer;

  /// Whether a rekey operation is currently in progress.
  bool rekeyInProgress = false;

  late final Uint8List _sessionIdBytes;

  // Packets decrypted before anyone listens are held, not dropped. The peer may
  // send its first application packet (e.g. a transfer offer) in the same burst
  // as the final handshake message, before the transfer engine has subscribed;
  // a plain broadcast stream silently discarded it and the sender waited forever.
  static const int _maxUndelivered = 256;
  final List<VayuPacket> _undelivered = [];
  late final StreamController<VayuPacket> _decryptedPacketsController =
      StreamController<VayuPacket>.broadcast(onListen: _flushUndelivered);

  void _flushUndelivered() {
    if (_undelivered.isEmpty) return;
    final pending = List<VayuPacket>.of(_undelivered);
    _undelivered.clear();
    pending.forEach(_decryptedPacketsController.add);
  }

  StreamSubscription<VayuPacket>? _incomingPacketSub;
  bool _isTerminated = false;

  /// Optional callback invoked when the session reaches its rekey threshold.
  void Function(SecureSessionImpl session)? onRekeyRequested;

  SecureSessionImpl({
    required this.connectionSession,
    required this.cryptoService,
    required this.derivedKeys,
    required this.sas,
    required this.localIdentityPubKey,
    required this.remoteIdentityPubKey,
    required this.isInitiator,
    required TrustLevel initialTrustLevel,
    int epoch = 0,
    this.rekeyThreshold = defaultRekeyThreshold,
    this.graceDrainDuration = defaultGraceDrainDuration,
  }) : _trustLevel = initialTrustLevel {
    _sessionIdBytes = _parseHexOrUuidToBytes(connectionSession.sessionId);

    // Directional key assignment based on role
    final Uint8List txKey;
    final Uint8List rxKey;
    final Uint8List txSalt;
    final Uint8List rxSalt;

    if (isInitiator) {
      txKey = Uint8List.fromList(derivedKeys.keyInitToResp);
      rxKey = Uint8List.fromList(derivedKeys.keyRespToInit);
      txSalt = Uint8List.fromList(derivedKeys.saltInitNonce);
      rxSalt = Uint8List.fromList(derivedKeys.saltRespNonce);
    } else {
      txKey = Uint8List.fromList(derivedKeys.keyRespToInit);
      rxKey = Uint8List.fromList(derivedKeys.keyInitToResp);
      txSalt = Uint8List.fromList(derivedKeys.saltRespNonce);
      rxSalt = Uint8List.fromList(derivedKeys.saltInitNonce);
    }

    _activeEpoch = KeyEpochMaterial(
      epoch: epoch,
      txKey: txKey,
      rxKey: rxKey,
      txSalt: txSalt,
      rxSalt: rxSalt,
      confirmKey: Uint8List.fromList(derivedKeys.confirmKey),
      replayFilter: ReplayProtectionFilter(),
    );

    _initPacketPipeline();
  }

  @override
  String get sessionId => connectionSession.sessionId;

  /// Returns the 16-byte raw session ID bytes.
  Uint8List get sessionIdBytes => _parseHexOrUuidToBytes(sessionId);

  @override
  String get remoteDeviceId => connectionSession.remoteDeviceId;

  @override
  SessionState get state => connectionSession.state;

  @override
  bool get isEstablished => state == SessionState.secured && !_isTerminated;

  TrustLevel get trustLevel => _trustLevel;
  int get txSequence => _txSequence;

  /// Current active key epoch.
  int get epoch => _activeEpoch.epoch;
  int get currentEpoch => _activeEpoch.epoch;

  /// Active confirmation key for the current epoch.
  Uint8List get activeConfirmKey => _activeEpoch.confirmKey;

  /// Stream of decrypted, integrity-verified application packets.
  @override
  Stream<VayuPacket> get incomingDecryptedPackets =>
      _decryptedPacketsController.stream;

  void updateTrustLevel(TrustLevel newLevel) {
    _trustLevel = newLevel;
  }

  /// Transitions the session to a new key epoch [newEpoch] with fresh [newKeys].
  ///
  /// Resets `txSequence` to 0, installs fresh directional keys, and retains
  /// the old epoch keys in read-only mode for [graceDrainDuration].
  void applyNewEpoch(DerivedSessionKeys newKeys, int newEpoch) {
    if (_isTerminated) {
      throw StateError('Cannot apply new key epoch on terminated session');
    }
    if (newEpoch != _activeEpoch.epoch + 1) {
      throw ArgumentError(
        'Invalid new epoch: expected ${_activeEpoch.epoch + 1}, got $newEpoch',
      );
    }

    AppLogger.info(
      'SecureSession',
      'Activating key epoch $newEpoch (retiring epoch ${_activeEpoch.epoch}) for session $sessionId',
    );

    // Cancel existing grace timer if running and wipe older retained epoch
    _gracePeriodTimer?.cancel();
    _retainedPreviousEpoch?.wipe();

    // Retain previous active epoch
    _retainedPreviousEpoch = _activeEpoch;

    // Directional keys for new epoch
    final Uint8List txKey;
    final Uint8List rxKey;
    final Uint8List txSalt;
    final Uint8List rxSalt;

    if (isInitiator) {
      txKey = Uint8List.fromList(newKeys.keyInitToResp);
      rxKey = Uint8List.fromList(newKeys.keyRespToInit);
      txSalt = Uint8List.fromList(newKeys.saltInitNonce);
      rxSalt = Uint8List.fromList(newKeys.saltRespNonce);
    } else {
      txKey = Uint8List.fromList(newKeys.keyRespToInit);
      rxKey = Uint8List.fromList(newKeys.keyInitToResp);
      txSalt = Uint8List.fromList(newKeys.saltRespNonce);
      rxSalt = Uint8List.fromList(newKeys.saltInitNonce);
    }

    _activeEpoch = KeyEpochMaterial(
      epoch: newEpoch,
      txKey: txKey,
      rxKey: rxKey,
      txSalt: txSalt,
      rxSalt: rxSalt,
      confirmKey: Uint8List.fromList(newKeys.confirmKey),
      replayFilter: ReplayProtectionFilter(),
    );

    // Reset sequence counter to 0 in new epoch
    _txSequence = 0;
    rekeyInProgress = false;

    // Schedule grace period cleanup
    _gracePeriodTimer = Timer(graceDrainDuration, () {
      AppLogger.info(
        'SecureSession',
        'Grace drain period expired for epoch ${_retainedPreviousEpoch?.epoch}; zeroing old keys',
      );
      _retainedPreviousEpoch?.wipe();
      _retainedPreviousEpoch = null;
      _gracePeriodTimer = null;
    });
  }

  // Inbound packets start decrypting as soon as they arrive (the platform
  // cipher works on a background thread), but the replay check, the replay
  // commit and delivery run strictly in arrival order, so a transfer offer is
  // always delivered before the chunks that follow it.
  Future<void> _rxChain = Future<void>.value();

  void _enqueueInbound(VayuPacket packet) {
    final opening = _startOpening(packet);
    _rxChain = _rxChain
        .then((_) => _deliverInbound(packet, opening))
        .catchError((Object _) {});
  }

  /// Processes application packets that reached the responder while it was still
  /// verifying the initiator's AuthConfirm. The initiator is secured one message
  /// earlier and may send its first packet immediately; without this replay that
  /// packet was dropped and the sender waited forever for a reply.
  void replayEarlyPackets(List<VayuPacket> packets) {
    packets.forEach(_enqueueInbound);
  }

  /// Packet types that never carry encrypted application data.
  static bool isControlPacket(VayuPacket packet) =>
      packet.packetType == PacketType.authExchange ||
      packet.packetType == PacketType.ping ||
      packet.packetType == PacketType.pong ||
      packet.packetType == PacketType.sessionTeardown;

  void _initPacketPipeline() {
    _incomingPacketSub = connectionSession.incomingPackets.listen(
      _enqueueInbound,
      onError: (e) {
        AppLogger.warning('SecureSession', 'Transport packet error: $e');
        if (!_decryptedPacketsController.isClosed) {
          _decryptedPacketsController.addError(e);
        }
      },
      onDone: () {
        terminate();
      },
    );
  }

  /// Starts decrypting [packet]; null for control packets. Errors are kept in
  /// the returned future and surface, in order, in [_deliverInbound].
  Future<_OpenedPacket>? _startOpening(VayuPacket packet) {
    if (isControlPacket(packet)) return null;
    final opening = _openPacket(packet);
    // Handled when delivered; never an unhandled error meanwhile.
    opening.ignore();
    return opening;
  }

  Future<_OpenedPacket> _openPacket(VayuPacket packet) async {
    if (packet.payload.length < EncryptedEnvelope.minEnvelopeSize) {
      throw SecurityError(
        'Incoming packet payload too short for EncryptedEnvelope',
      );
    }
    final envelope = EncryptedEnvelope.fromBytes(packet.payload);
    final epochMaterial = _epochFor(envelope.epoch);
    final nonce = _constructNonce(
      epochMaterial.rxSalt,
      envelope.sequenceNumber,
    );
    // Canonical 76-byte AAD from packet header + sessionId + nonce.
    final aad = CryptoService.constructAad(
      magic1: VayuPacket.magic1,
      magic2: VayuPacket.magic2,
      protocolVersion: packet.version,
      packetTypeCode: packet.packetType.code,
      packetId: packet.packetId,
      sourceDeviceId: packet.sourceDeviceId,
      destinationDeviceId: packet.destinationDeviceId,
      payloadLength: packet.payload.length,
      sessionId: _sessionIdBytes,
      aeadNonce: nonce,
    );
    final Uint8List plaintext;
    try {
      plaintext = await cryptoService.decryptAead(
        ciphertext: envelope.ciphertext,
        authTag: envelope.authTag,
        secretKeyBytes: epochMaterial.rxKey,
        nonce: nonce,
        aad: aad,
      );
    } catch (e) {
      throw SecurityError('AEAD message authentication failed: $e');
    }
    return _OpenedPacket(epochMaterial, envelope.sequenceNumber, plaintext);
  }

  Future<void> _deliverInbound(
    VayuPacket packet,
    Future<_OpenedPacket>? opening,
  ) async {
    if (opening == null) return;
    try {
      _OpenedPacket opened;
      try {
        opened = await opening;
      } on _EpochNotYetActive {
        // Sent just after a rekey that this side applies while handling the
        // packets before it; by now the new epoch is active.
        opened = await _openPacket(packet);
      }
      // Replay state changes only after authentication, in arrival order.
      _checkReplay(opened.epoch, opened.sequenceNumber);
      opened.epoch.replayFilter.commitSequence(opened.sequenceNumber);

      final decryptedPacket = packet.copyWith(payload: opened.plaintext);
      if (!_decryptedPacketsController.isClosed) {
        if (_decryptedPacketsController.hasListener) {
          _decryptedPacketsController.add(decryptedPacket);
        } else if (_undelivered.length < _maxUndelivered) {
          _undelivered.add(decryptedPacket);
        } else {
          AppLogger.warning(
            'SecureSession',
            'Dropping packet ${packet.packetId}: no listener and buffer full',
          );
        }
      }
    } catch (e, stack) {
      AppLogger.warning(
        'SecureSession',
        'Failed to decrypt application packet ${packet.packetId}: $e',
      );
      if (!_decryptedPacketsController.isClosed) {
        _decryptedPacketsController.addError(
          SecurityError('Failed to decrypt packet: $e', e),
          stack,
        );
      }
    }
  }

  /// Key material for an envelope epoch: the active one, or the previous one
  /// during its grace period.
  KeyEpochMaterial _epochFor(int epoch) {
    if (epoch == _activeEpoch.epoch) return _activeEpoch;
    final previous = _retainedPreviousEpoch;
    if (previous != null && epoch == previous.epoch) return previous;
    if (epoch < _activeEpoch.epoch) {
      throw SecurityError(
        'Stale key epoch: envelope epoch $epoch is older than retained window (active: ${_activeEpoch.epoch})',
      );
    }
    throw _EpochNotYetActive(
      'Future unnegotiated key epoch: received $epoch, active: ${_activeEpoch.epoch}',
    );
  }

  void _checkReplay(KeyEpochMaterial epochMaterial, int sequenceNumber) {
    final decision = epochMaterial.replayFilter.checkSequence(sequenceNumber);
    if (decision == ReplayDecision.rejectDuplicate) {
      throw SecurityError(
        'Replay Protection: Duplicate sequence number $sequenceNumber in epoch ${epochMaterial.epoch} rejected',
      );
    }
    if (decision == ReplayDecision.rejectStale) {
      throw SecurityError(
        'Replay Protection: Stale sequence number $sequenceNumber in epoch ${epochMaterial.epoch} fell off sliding window',
      );
    }
  }

  @override
  Future<Uint8List> encryptPayload(
    Uint8List plaintext, {
    Uint8List? associatedData,
  }) async {
    if (!isEstablished) {
      throw StateError(
        'Cannot encrypt payload: session is not secured (state: $state)',
      );
    }

    if (_txSequence >= maxPacketsPerKey) {
      throw SecurityError(
        'Per-key packet limit exceeded ($maxPacketsPerKey). Mandatory rekey required.',
      );
    }

    // Trigger soft rekey when threshold is reached
    if (_txSequence >= rekeyThreshold && !rekeyInProgress) {
      rekeyInProgress = true;
      onRekeyRequested?.call(this);
    }

    if (associatedData == null || associatedData.length != 76) {
      throw ArgumentError.value(
        associatedData?.length,
        'associatedData',
        'AEAD Associated Data must be exactly 76 bytes',
      );
    }

    // Reserve the sequence number before the first await. Incrementing it
    // after encryption let two concurrent sends (an ACK and a retransmit, for
    // example) use the same number, which reused the AES-GCM nonce and made
    // the receiver drop the second packet as a replay.
    final epochMaterial = _activeEpoch;
    final seq = _txSequence++;
    final nonce = _constructNonce(epochMaterial.txSalt, seq);

    final result = await cryptoService.encryptAead(
      plaintext: plaintext,
      secretKeyBytes: epochMaterial.txKey,
      nonce: nonce,
      aad: associatedData,
    );

    final envelope = EncryptedEnvelope(
      epoch: epochMaterial.epoch,
      sequenceNumber: seq,
      ciphertext: result.ciphertext,
      authTag: result.authTag,
    );
    return envelope.toBytes();
  }

  @override
  Future<Uint8List> decryptPayload(
    Uint8List ciphertext, {
    Uint8List? associatedData,
  }) async {
    if (_isTerminated) {
      throw StateError('Cannot decrypt payload on terminated session');
    }

    if (associatedData == null || associatedData.length != 76) {
      throw ArgumentError.value(
        associatedData?.length,
        'associatedData',
        'AEAD Associated Data must be exactly 76 bytes',
      );
    }

    final envelope = EncryptedEnvelope.fromBytes(ciphertext);
    final epochMaterial = _epochFor(envelope.epoch);

    // Replay Protection Pre-Check on the corresponding epoch filter
    _checkReplay(epochMaterial, envelope.sequenceNumber);

    final nonce = _constructNonce(
      epochMaterial.rxSalt,
      envelope.sequenceNumber,
    );

    // Decrypt and authenticate tag
    final Uint8List plaintext;
    try {
      plaintext = await cryptoService.decryptAead(
        ciphertext: envelope.ciphertext,
        authTag: envelope.authTag,
        secretKeyBytes: epochMaterial.rxKey,
        nonce: nonce,
        aad: associatedData,
      );
    } catch (e) {
      throw SecurityError('AEAD message authentication failed: $e');
    }

    // Post-Authentication Commit: Only update replay state after AEAD verification succeeds
    epochMaterial.replayFilter.commitSequence(envelope.sequenceNumber);

    return plaintext;
  }

  /// Wraps, encrypts, and sends [packet] over the active connection session.
  @override
  Future<void> sendEncryptedPacket(VayuPacket packet) async {
    if (!isEstablished) {
      throw StateError('Cannot send encrypted packet on unestablished session');
    }

    final envelopeLength =
        packet.payload.length + EncryptedEnvelope.minEnvelopeSize;
    final nonce = _constructNonce(_activeEpoch.txSalt, _txSequence);

    final aad = CryptoService.constructAad(
      magic1: VayuPacket.magic1,
      magic2: VayuPacket.magic2,
      protocolVersion: packet.version,
      packetTypeCode: packet.packetType.code,
      packetId: packet.packetId,
      sourceDeviceId: packet.sourceDeviceId,
      destinationDeviceId: packet.destinationDeviceId,
      payloadLength: envelopeLength,
      sessionId: _sessionIdBytes,
      aeadNonce: nonce,
    );

    // encryptPayload reserves the sequence number synchronously, so packets
    // are numbered in call order; encrypting the next packet may overlap with
    // writing this one, but writes leave in that same order.
    final sealing = encryptPayload(packet.payload, associatedData: aad);
    final previousWrite = _txWriteChain;
    final written = Completer<void>();
    _txWriteChain = written.future;

    final Uint8List encryptedBytes;
    try {
      encryptedBytes = await sealing;
    } catch (_) {
      previousWrite.whenComplete(written.complete);
      rethrow;
    }
    try {
      await previousWrite;
      await connectionSession.sendPacket(
        packet.copyWith(payload: encryptedBytes),
      );
    } finally {
      written.complete();
    }
  }

  // Completes when the most recently queued packet has been written (or has
  // failed). Never completes with an error.
  Future<void> _txWriteChain = Future<void>.value();

  @override
  Future<void> terminate() async {
    if (_isTerminated) return;
    _isTerminated = true;

    AppLogger.info('SecureSession', 'Terminating secure session $sessionId');

    _gracePeriodTimer?.cancel();
    _gracePeriodTimer = null;

    // Wipe in-memory key materials for all active and retained epochs
    derivedKeys.wipe();
    _activeEpoch.wipe();
    _retainedPreviousEpoch?.wipe();
    _retainedPreviousEpoch = null;

    await _incomingPacketSub?.cancel();
    _incomingPacketSub = null;

    if (!_decryptedPacketsController.isClosed) {
      await _decryptedPacketsController.close();
    }

    // Close underlying connection session if still active
    if (connectionSession.isActive) {
      await connectionSession.close(reason: 'secure_session_terminated');
    }
  }

  Uint8List _constructNonce(Uint8List salt, int sequenceNumber) {
    final nonce = Uint8List(12);
    nonce.setRange(0, 4, salt);
    final byteData = ByteData.sublistView(nonce);
    byteData.setUint64(4, sequenceNumber, Endian.big);
    return nonce;
  }

  static Uint8List _parseHexOrUuidToBytes(String str) {
    final clean = str.replaceAll('-', '').toLowerCase();
    if (clean.length != 32) {
      throw FormatException('Invalid UUID/Hex string length: ${clean.length}');
    }
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}

/// A decrypted packet waiting for its in-order replay check and delivery.
class _OpenedPacket {
  final KeyEpochMaterial epoch;
  final int sequenceNumber;
  final Uint8List plaintext;

  _OpenedPacket(this.epoch, this.sequenceNumber, this.plaintext);
}

/// An envelope from a key epoch this side has not activated yet.
class _EpochNotYetActive extends SecurityError {
  _EpochNotYetActive(super.message);
}
