import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Subtypes carried within binary PacketType.authExchange (0x03) payloads.
enum AuthExchangeSubtype {
  init(0x01),
  response(0x02),
  confirm(0x03),
  rekeyInit(0x11),
  rekeyResponse(0x12),
  rekeyConfirm(0x13);

  final int code;
  const AuthExchangeSubtype(this.code);

  static AuthExchangeSubtype fromCode(int code) {
    for (final subtype in AuthExchangeSubtype.values) {
      if (subtype.code == code) return subtype;
    }
    throw FormatException(
      'Unknown authExchange subtype code: 0x${code.toRadixString(16)}',
    );
  }
}

/// Phase 1 of 3-Way Key Exchange: Initiator -> Responder.
/// Exact Wire Size: 180 bytes.
class AuthInitPayload {
  static const int payloadSize = 180;
  static const int defaultProtocolVersion = 1;
  static const int defaultCipherSuite =
      0x0001; // Ed25519 + X25519 + HKDF-SHA256 + AES-256-GCM

  final int protocolVersion;
  final int cipherSuite;
  final Uint8List sessionId; // 16 bytes
  final Uint8List ephemeralPubKey; // 32 bytes X25519
  final Uint8List nonce; // 32 bytes CSPRNG
  final Uint8List identityPubKey; // 32 bytes Ed25519
  final Uint8List signature; // 64 bytes Ed25519 signature over M_init

  AuthInitPayload({
    this.protocolVersion = defaultProtocolVersion,
    this.cipherSuite = defaultCipherSuite,
    required this.sessionId,
    required this.ephemeralPubKey,
    required this.nonce,
    required this.identityPubKey,
    required this.signature,
  }) {
    if (sessionId.length != 16) {
      throw ArgumentError.value(
        sessionId.length,
        'sessionId',
        'Must be 16 bytes',
      );
    }
    if (ephemeralPubKey.length != 32) {
      throw ArgumentError.value(
        ephemeralPubKey.length,
        'ephemeralPubKey',
        'Must be 32 bytes',
      );
    }
    if (nonce.length != 32) {
      throw ArgumentError.value(nonce.length, 'nonce', 'Must be 32 bytes');
    }
    if (identityPubKey.length != 32) {
      throw ArgumentError.value(
        identityPubKey.length,
        'identityPubKey',
        'Must be 32 bytes',
      );
    }
    if (signature.length != 64) {
      throw ArgumentError.value(
        signature.length,
        'signature',
        'Must be 64 bytes',
      );
    }
  }

  /// Encodes this payload to exact 180 bytes.
  Uint8List toBytes() {
    final buffer = Uint8List(payloadSize);
    final byteData = ByteData.sublistView(buffer);

    buffer[0] = AuthExchangeSubtype.init.code;
    buffer[1] = protocolVersion;
    byteData.setUint16(2, cipherSuite, Endian.big);

    buffer.setRange(4, 20, sessionId);
    buffer.setRange(20, 52, ephemeralPubKey);
    buffer.setRange(52, 84, nonce);
    buffer.setRange(84, 116, identityPubKey);
    buffer.setRange(116, 180, signature);

    return buffer;
  }

  /// Deserializes exact 180-byte wire frame.
  factory AuthInitPayload.fromBytes(Uint8List bytes) {
    if (bytes.length != payloadSize) {
      throw FormatException(
        'Invalid AuthInitPayload length: expected $payloadSize bytes, got ${bytes.length}',
      );
    }
    if (bytes[0] != AuthExchangeSubtype.init.code) {
      throw FormatException(
        'Invalid subtype for AuthInitPayload: expected 0x01, got 0x${bytes[0].toRadixString(16)}',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final protocolVersion = bytes[1];
    final cipherSuite = byteData.getUint16(2, Endian.big);

    final sessionId = Uint8List.fromList(bytes.sublist(4, 20));
    final ephemeralPubKey = Uint8List.fromList(bytes.sublist(20, 52));
    final nonce = Uint8List.fromList(bytes.sublist(52, 84));
    final identityPubKey = Uint8List.fromList(bytes.sublist(84, 116));
    final signature = Uint8List.fromList(bytes.sublist(116, 180));

    return AuthInitPayload(
      protocolVersion: protocolVersion,
      cipherSuite: cipherSuite,
      sessionId: sessionId,
      ephemeralPubKey: ephemeralPubKey,
      nonce: nonce,
      identityPubKey: identityPubKey,
      signature: signature,
    );
  }

  /// Constructs the canonical 168-byte M_init message signed by the Initiator's Ed25519 key.
  static Uint8List constructSigningMessage({
    int protocolVersion = defaultProtocolVersion,
    int cipherSuite = defaultCipherSuite,
    required Uint8List sessionId,
    required Uint8List initiatorDeviceId,
    required Uint8List responderDeviceId,
    required Uint8List initiatorEphemeralPubKey,
    required Uint8List initiatorNonce,
    required Uint8List initiatorIdentityPubKey,
  }) {
    final domainTag = utf8.encode('SiloSend-v1-AuthInit:'); // 21 bytes
    const totalLength = 168; // 21 + 1 + 2 + 16 + 16 + 16 + 32 + 32 + 32 = 168
    final buffer = Uint8List(totalLength);
    final byteData = ByteData.sublistView(buffer);

    buffer.setRange(0, 21, domainTag);
    buffer[21] = protocolVersion;
    byteData.setUint16(22, cipherSuite, Endian.big);

    buffer.setRange(24, 40, sessionId);
    buffer.setRange(40, 56, initiatorDeviceId);
    buffer.setRange(56, 72, responderDeviceId);
    buffer.setRange(72, 104, initiatorEphemeralPubKey);
    buffer.setRange(104, 136, initiatorNonce);
    buffer.setRange(136, 168, initiatorIdentityPubKey);

    return buffer;
  }
}

/// Phase 2 of 3-Way Key Exchange: Responder -> Initiator.
/// Exact Wire Size: 212 bytes.
class AuthResponsePayload {
  static const int payloadSize = 212;
  static const int defaultProtocolVersion = 1;
  static const int defaultCipherSuite = 0x0001;

  final int protocolVersion;
  final int cipherSuite;
  final Uint8List sessionId; // 16 bytes
  final Uint8List ephemeralPubKey; // 32 bytes X25519
  final Uint8List nonce; // 32 bytes CSPRNG
  final Uint8List identityPubKey; // 32 bytes Ed25519
  final Uint8List signature; // 64 bytes Ed25519 signature over M_resp
  final Uint8List confirmMac; // 32 bytes HMAC-SHA256(K_confirm, "resp-confirm:" || H_transcript)

  AuthResponsePayload({
    this.protocolVersion = defaultProtocolVersion,
    this.cipherSuite = defaultCipherSuite,
    required this.sessionId,
    required this.ephemeralPubKey,
    required this.nonce,
    required this.identityPubKey,
    required this.signature,
    required this.confirmMac,
  }) {
    if (sessionId.length != 16) {
      throw ArgumentError.value(
        sessionId.length,
        'sessionId',
        'Must be 16 bytes',
      );
    }
    if (ephemeralPubKey.length != 32) {
      throw ArgumentError.value(
        ephemeralPubKey.length,
        'ephemeralPubKey',
        'Must be 32 bytes',
      );
    }
    if (nonce.length != 32) {
      throw ArgumentError.value(nonce.length, 'nonce', 'Must be 32 bytes');
    }
    if (identityPubKey.length != 32) {
      throw ArgumentError.value(
        identityPubKey.length,
        'identityPubKey',
        'Must be 32 bytes',
      );
    }
    if (signature.length != 64) {
      throw ArgumentError.value(
        signature.length,
        'signature',
        'Must be 64 bytes',
      );
    }
    if (confirmMac.length != 32) {
      throw ArgumentError.value(
        confirmMac.length,
        'confirmMac',
        'Must be 32 bytes',
      );
    }
  }

  /// Encodes this payload to exact 212 bytes.
  Uint8List toBytes() {
    final buffer = Uint8List(payloadSize);
    final byteData = ByteData.sublistView(buffer);

    buffer[0] = AuthExchangeSubtype.response.code;
    buffer[1] = protocolVersion;
    byteData.setUint16(2, cipherSuite, Endian.big);

    buffer.setRange(4, 20, sessionId);
    buffer.setRange(20, 52, ephemeralPubKey);
    buffer.setRange(52, 84, nonce);
    buffer.setRange(84, 116, identityPubKey);
    buffer.setRange(116, 180, signature);
    buffer.setRange(180, 212, confirmMac);

    return buffer;
  }

  /// Deserializes exact 212-byte wire frame.
  factory AuthResponsePayload.fromBytes(Uint8List bytes) {
    if (bytes.length != payloadSize) {
      throw FormatException(
        'Invalid AuthResponsePayload length: expected $payloadSize bytes, got ${bytes.length}',
      );
    }
    if (bytes[0] != AuthExchangeSubtype.response.code) {
      throw FormatException(
        'Invalid subtype for AuthResponsePayload: expected 0x02, got 0x${bytes[0].toRadixString(16)}',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final protocolVersion = bytes[1];
    final cipherSuite = byteData.getUint16(2, Endian.big);

    final sessionId = Uint8List.fromList(bytes.sublist(4, 20));
    final ephemeralPubKey = Uint8List.fromList(bytes.sublist(20, 52));
    final nonce = Uint8List.fromList(bytes.sublist(52, 84));
    final identityPubKey = Uint8List.fromList(bytes.sublist(84, 116));
    final signature = Uint8List.fromList(bytes.sublist(116, 180));
    final confirmMac = Uint8List.fromList(bytes.sublist(180, 212));

    return AuthResponsePayload(
      protocolVersion: protocolVersion,
      cipherSuite: cipherSuite,
      sessionId: sessionId,
      ephemeralPubKey: ephemeralPubKey,
      nonce: nonce,
      identityPubKey: identityPubKey,
      signature: signature,
      confirmMac: confirmMac,
    );
  }

  /// Constructs the canonical 204-byte M_resp message signed by Responder's Ed25519 key.
  static Uint8List constructSigningMessage({
    int protocolVersion = defaultProtocolVersion,
    int cipherSuite = defaultCipherSuite,
    required Uint8List sessionId,
    required Uint8List responderDeviceId,
    required Uint8List initiatorDeviceId,
    required Uint8List responderEphemeralPubKey,
    required Uint8List responderNonce,
    required Uint8List responderIdentityPubKey,
    required Uint8List
    initiatorChallengeHash, // 32 bytes SHA-256(M_init || Sig_A)
  }) {
    final domainTag = utf8.encode('SiloSend-v1-AuthResponse:'); // 25 bytes
    const totalLength =
        204; // 25 + 1 + 2 + 16 + 16 + 16 + 32 + 32 + 32 + 32 = 204
    final buffer = Uint8List(totalLength);
    final byteData = ByteData.sublistView(buffer);

    buffer.setRange(0, 25, domainTag);
    buffer[25] = protocolVersion;
    byteData.setUint16(26, cipherSuite, Endian.big);

    buffer.setRange(28, 44, sessionId);
    buffer.setRange(44, 60, responderDeviceId);
    buffer.setRange(60, 76, initiatorDeviceId);
    buffer.setRange(76, 108, responderEphemeralPubKey);
    buffer.setRange(108, 140, responderNonce);
    buffer.setRange(140, 172, responderIdentityPubKey);
    buffer.setRange(172, 204, initiatorChallengeHash);

    return buffer;
  }
}

/// Phase 3 of 3-Way Key Exchange: Initiator -> Responder.
/// Exact Wire Size: 49 bytes.
class AuthConfirmPayload {
  static const int payloadSize = 49;

  final Uint8List sessionId; // 16 bytes
  final Uint8List confirmMac; // 32 bytes HMAC-SHA256(K_confirm, "init-confirm:" || H_transcript)

  AuthConfirmPayload({required this.sessionId, required this.confirmMac}) {
    if (sessionId.length != 16) {
      throw ArgumentError.value(
        sessionId.length,
        'sessionId',
        'Must be 16 bytes',
      );
    }
    if (confirmMac.length != 32) {
      throw ArgumentError.value(
        confirmMac.length,
        'confirmMac',
        'Must be 32 bytes',
      );
    }
  }

  /// Encodes this payload to exact 49 bytes.
  Uint8List toBytes() {
    final buffer = Uint8List(payloadSize);
    buffer[0] = AuthExchangeSubtype.confirm.code;
    buffer.setRange(1, 17, sessionId);
    buffer.setRange(17, 49, confirmMac);
    return buffer;
  }

  /// Deserializes exact 49-byte wire frame.
  factory AuthConfirmPayload.fromBytes(Uint8List bytes) {
    if (bytes.length != payloadSize) {
      throw FormatException(
        'Invalid AuthConfirmPayload length: expected $payloadSize bytes, got ${bytes.length}',
      );
    }
    if (bytes[0] != AuthExchangeSubtype.confirm.code) {
      throw FormatException(
        'Invalid subtype for AuthConfirmPayload: expected 0x03, got 0x${bytes[0].toRadixString(16)}',
      );
    }

    final sessionId = Uint8List.fromList(bytes.sublist(1, 17));
    final confirmMac = Uint8List.fromList(bytes.sublist(17, 49));

    return AuthConfirmPayload(sessionId: sessionId, confirmMac: confirmMac);
  }
}

/// Helper utility to compute canonical handshake transcripts and challenge hashes.
class HandshakeTranscriptHelper {
  /// Computes SHA-256(M_init || Sig_A) (32 bytes).
  static Uint8List computeInitiatorChallengeHash({
    required Uint8List mInit,
    required Uint8List sigA,
  }) {
    final buffer = Uint8List(mInit.length + sigA.length);
    buffer.setRange(0, mInit.length, mInit);
    buffer.setRange(mInit.length, buffer.length, sigA);
    final digest = crypto.sha256.convert(buffer);
    return Uint8List.fromList(digest.bytes);
  }

  /// Computes the canonical 32-byte H_transcript from the exact 500-byte transcript.
  /// Transcript = M_init (168B) || Sig_A (64B) || M_resp (204B) || Sig_B (64B)
  static Uint8List computeTranscriptHash({
    required Uint8List mInit,
    required Uint8List sigA,
    required Uint8List mResp,
    required Uint8List sigB,
  }) {
    const expectedSize = 500;
    final totalSize = mInit.length + sigA.length + mResp.length + sigB.length;
    if (totalSize != expectedSize) {
      throw ArgumentError(
        'Invalid transcript length: expected $expectedSize bytes, got $totalSize bytes',
      );
    }

    final buffer = Uint8List(expectedSize);
    int offset = 0;

    buffer.setRange(offset, offset + mInit.length, mInit);
    offset += mInit.length;

    buffer.setRange(offset, offset + sigA.length, sigA);
    offset += sigA.length;

    buffer.setRange(offset, offset + mResp.length, mResp);
    offset += mResp.length;

    buffer.setRange(offset, offset + sigB.length, sigB);

    final digest = crypto.sha256.convert(buffer);
    return Uint8List.fromList(digest.bytes);
  }
}

/// Phase 1 of Rekey-v1 In-Band Key Rotation: Initiator -> Responder.
/// Exact Wire Size: 180 bytes.
class RekeyInitPayload {
  static const int payloadSize = 180;
  static const int defaultProtocolVersion = 1;

  final int protocolVersion;
  final int targetEpoch; // uint16
  final Uint8List sessionId; // 16 bytes
  final Uint8List ephemeralPubKey; // 32 bytes X25519
  final Uint8List nonce; // 32 bytes CSPRNG
  final Uint8List prevEpochMac; // 32 bytes HMAC-SHA256(K_confirm^(E), ...)
  final Uint8List signature; // 64 bytes Ed25519 over M_rekey_init

  RekeyInitPayload({
    this.protocolVersion = defaultProtocolVersion,
    required this.targetEpoch,
    required this.sessionId,
    required this.ephemeralPubKey,
    required this.nonce,
    required this.prevEpochMac,
    required this.signature,
  }) {
    if (targetEpoch <= 0 || targetEpoch > 65535) {
      throw ArgumentError.value(
        targetEpoch,
        'targetEpoch',
        'Target epoch must be between 1 and 65535',
      );
    }
    if (sessionId.length != 16) {
      throw ArgumentError.value(
        sessionId.length,
        'sessionId',
        'Must be 16 bytes',
      );
    }
    if (ephemeralPubKey.length != 32) {
      throw ArgumentError.value(
        ephemeralPubKey.length,
        'ephemeralPubKey',
        'Must be 32 bytes',
      );
    }
    if (nonce.length != 32) {
      throw ArgumentError.value(nonce.length, 'nonce', 'Must be 32 bytes');
    }
    if (prevEpochMac.length != 32) {
      throw ArgumentError.value(
        prevEpochMac.length,
        'prevEpochMac',
        'Must be 32 bytes',
      );
    }
    if (signature.length != 64) {
      throw ArgumentError.value(
        signature.length,
        'signature',
        'Must be 64 bytes',
      );
    }
  }

  /// Encodes this payload to exact 180 bytes.
  Uint8List toBytes() {
    final buffer = Uint8List(payloadSize);
    final byteData = ByteData.sublistView(buffer);

    buffer[0] = AuthExchangeSubtype.rekeyInit.code; // 0x11
    buffer[1] = protocolVersion;
    byteData.setUint16(2, targetEpoch, Endian.big);

    buffer.setRange(4, 20, sessionId);
    buffer.setRange(20, 52, ephemeralPubKey);
    buffer.setRange(52, 84, nonce);
    buffer.setRange(84, 116, prevEpochMac);
    buffer.setRange(116, 180, signature);

    return buffer;
  }

  /// Deserializes exact 180-byte wire frame.
  factory RekeyInitPayload.fromBytes(Uint8List bytes) {
    if (bytes.length != payloadSize) {
      throw FormatException(
        'Invalid RekeyInitPayload length: expected $payloadSize bytes, got ${bytes.length}',
      );
    }
    if (bytes[0] != AuthExchangeSubtype.rekeyInit.code) {
      throw FormatException(
        'Invalid subtype for RekeyInitPayload: expected 0x11, got 0x${bytes[0].toRadixString(16)}',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final protocolVersion = bytes[1];
    final targetEpoch = byteData.getUint16(2, Endian.big);

    final sessionId = Uint8List.fromList(bytes.sublist(4, 20));
    final ephemeralPubKey = Uint8List.fromList(bytes.sublist(20, 52));
    final nonce = Uint8List.fromList(bytes.sublist(52, 84));
    final prevEpochMac = Uint8List.fromList(bytes.sublist(84, 116));
    final signature = Uint8List.fromList(bytes.sublist(116, 180));

    return RekeyInitPayload(
      protocolVersion: protocolVersion,
      targetEpoch: targetEpoch,
      sessionId: sessionId,
      ephemeralPubKey: ephemeralPubKey,
      nonce: nonce,
      prevEpochMac: prevEpochMac,
      signature: signature,
    );
  }

  /// Constructs the canonical 169-byte M_rekey_init message signed by the Initiator's Ed25519 key.
  static Uint8List constructSigningMessage({
    int protocolVersion = defaultProtocolVersion,
    required int targetEpoch,
    required Uint8List sessionId,
    required Uint8List initiatorDeviceId,
    required Uint8List responderDeviceId,
    required Uint8List initiatorEphemeralPubKey,
    required Uint8List initiatorNonce,
    required Uint8List initiatorIdentityPubKey,
  }) {
    final domainTag = utf8.encode('SiloSend-v1-RekeyInit:'); // 22 bytes
    const totalLength = 169; // 22 + 1 + 2 + 16 + 16 + 16 + 32 + 32 + 32 = 169
    final buffer = Uint8List(totalLength);
    final byteData = ByteData.sublistView(buffer);

    buffer.setRange(0, 22, domainTag);
    buffer[22] = protocolVersion;
    byteData.setUint16(23, targetEpoch, Endian.big);

    buffer.setRange(25, 41, sessionId);
    buffer.setRange(41, 57, initiatorDeviceId);
    buffer.setRange(57, 73, responderDeviceId);
    buffer.setRange(73, 105, initiatorEphemeralPubKey);
    buffer.setRange(105, 137, initiatorNonce);
    buffer.setRange(137, 169, initiatorIdentityPubKey);

    return buffer;
  }
}

/// Phase 2 of Rekey-v1 In-Band Key Rotation: Responder -> Initiator.
/// Exact Wire Size: 212 bytes.
class RekeyResponsePayload {
  static const int payloadSize = 212;
  static const int defaultProtocolVersion = 1;

  final int protocolVersion;
  final int targetEpoch; // uint16
  final Uint8List sessionId; // 16 bytes
  final Uint8List ephemeralPubKey; // 32 bytes X25519
  final Uint8List nonce; // 32 bytes CSPRNG
  final Uint8List
  initChallengeHash; // 32 bytes SHA-256(M_rekey_init || sig_init)
  final Uint8List signature; // 64 bytes Ed25519 signature over M_rekey_resp
  final Uint8List confirmMac; // 32 bytes HMAC-SHA256(K_confirm^(E+1), "rekey-resp-confirm:" || H_rekey_transcript)

  RekeyResponsePayload({
    this.protocolVersion = defaultProtocolVersion,
    required this.targetEpoch,
    required this.sessionId,
    required this.ephemeralPubKey,
    required this.nonce,
    required this.initChallengeHash,
    required this.signature,
    required this.confirmMac,
  }) {
    if (targetEpoch <= 0 || targetEpoch > 65535) {
      throw ArgumentError.value(
        targetEpoch,
        'targetEpoch',
        'Target epoch must be between 1 and 65535',
      );
    }
    if (sessionId.length != 16) {
      throw ArgumentError.value(
        sessionId.length,
        'sessionId',
        'Must be 16 bytes',
      );
    }
    if (ephemeralPubKey.length != 32) {
      throw ArgumentError.value(
        ephemeralPubKey.length,
        'ephemeralPubKey',
        'Must be 32 bytes',
      );
    }
    if (nonce.length != 32) {
      throw ArgumentError.value(nonce.length, 'nonce', 'Must be 32 bytes');
    }
    if (initChallengeHash.length != 32) {
      throw ArgumentError.value(
        initChallengeHash.length,
        'initChallengeHash',
        'Must be 32 bytes',
      );
    }
    if (signature.length != 64) {
      throw ArgumentError.value(
        signature.length,
        'signature',
        'Must be 64 bytes',
      );
    }
    if (confirmMac.length != 32) {
      throw ArgumentError.value(
        confirmMac.length,
        'confirmMac',
        'Must be 32 bytes',
      );
    }
  }

  /// Encodes this payload to exact 212 bytes.
  Uint8List toBytes() {
    final buffer = Uint8List(payloadSize);
    final byteData = ByteData.sublistView(buffer);

    buffer[0] = AuthExchangeSubtype.rekeyResponse.code; // 0x12
    buffer[1] = protocolVersion;
    byteData.setUint16(2, targetEpoch, Endian.big);

    buffer.setRange(4, 20, sessionId);
    buffer.setRange(20, 52, ephemeralPubKey);
    buffer.setRange(52, 84, nonce);
    buffer.setRange(84, 116, initChallengeHash);
    buffer.setRange(116, 180, signature);
    buffer.setRange(180, 212, confirmMac);

    return buffer;
  }

  /// Deserializes exact 212-byte wire frame.
  factory RekeyResponsePayload.fromBytes(Uint8List bytes) {
    if (bytes.length != payloadSize) {
      throw FormatException(
        'Invalid RekeyResponsePayload length: expected $payloadSize bytes, got ${bytes.length}',
      );
    }
    if (bytes[0] != AuthExchangeSubtype.rekeyResponse.code) {
      throw FormatException(
        'Invalid subtype for RekeyResponsePayload: expected 0x12, got 0x${bytes[0].toRadixString(16)}',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final protocolVersion = bytes[1];
    final targetEpoch = byteData.getUint16(2, Endian.big);

    final sessionId = Uint8List.fromList(bytes.sublist(4, 20));
    final ephemeralPubKey = Uint8List.fromList(bytes.sublist(20, 52));
    final nonce = Uint8List.fromList(bytes.sublist(52, 84));
    final initChallengeHash = Uint8List.fromList(bytes.sublist(84, 116));
    final signature = Uint8List.fromList(bytes.sublist(116, 180));
    final confirmMac = Uint8List.fromList(bytes.sublist(180, 212));

    return RekeyResponsePayload(
      protocolVersion: protocolVersion,
      targetEpoch: targetEpoch,
      sessionId: sessionId,
      ephemeralPubKey: ephemeralPubKey,
      nonce: nonce,
      initChallengeHash: initChallengeHash,
      signature: signature,
      confirmMac: confirmMac,
    );
  }

  /// Constructs the canonical 205-byte M_rekey_resp message signed by Responder's Ed25519 key.
  static Uint8List constructSigningMessage({
    int protocolVersion = defaultProtocolVersion,
    required int targetEpoch,
    required Uint8List sessionId,
    required Uint8List responderDeviceId,
    required Uint8List initiatorDeviceId,
    required Uint8List responderEphemeralPubKey,
    required Uint8List responderNonce,
    required Uint8List responderIdentityPubKey,
    required Uint8List initiatorChallengeHash,
  }) {
    final domainTag = utf8.encode('SiloSend-v1-RekeyResponse:'); // 26 bytes
    const totalLength =
        205; // 26 + 1 + 2 + 16 + 16 + 16 + 32 + 32 + 32 + 32 = 205
    final buffer = Uint8List(totalLength);
    final byteData = ByteData.sublistView(buffer);

    buffer.setRange(0, 26, domainTag);
    buffer[26] = protocolVersion;
    byteData.setUint16(27, targetEpoch, Endian.big);

    buffer.setRange(29, 45, sessionId);
    buffer.setRange(45, 61, responderDeviceId);
    buffer.setRange(61, 77, initiatorDeviceId);
    buffer.setRange(77, 109, responderEphemeralPubKey);
    buffer.setRange(109, 141, responderNonce);
    buffer.setRange(141, 173, responderIdentityPubKey);
    buffer.setRange(173, 205, initiatorChallengeHash);

    return buffer;
  }
}

/// Phase 3 of Rekey-v1 In-Band Key Rotation: Initiator -> Responder.
/// Exact Wire Size: 51 bytes.
class RekeyConfirmPayload {
  static const int payloadSize = 51;

  final int targetEpoch; // uint16
  final Uint8List sessionId; // 16 bytes
  final Uint8List confirmMac; // 32 bytes HMAC-SHA256(K_confirm^(E+1), "rekey-init-confirm:" || H_rekey_transcript)

  RekeyConfirmPayload({
    required this.targetEpoch,
    required this.sessionId,
    required this.confirmMac,
  }) {
    if (targetEpoch <= 0 || targetEpoch > 65535) {
      throw ArgumentError.value(
        targetEpoch,
        'targetEpoch',
        'Target epoch must be between 1 and 65535',
      );
    }
    if (sessionId.length != 16) {
      throw ArgumentError.value(
        sessionId.length,
        'sessionId',
        'Must be 16 bytes',
      );
    }
    if (confirmMac.length != 32) {
      throw ArgumentError.value(
        confirmMac.length,
        'confirmMac',
        'Must be 32 bytes',
      );
    }
  }

  /// Encodes this payload to exact 51 bytes.
  Uint8List toBytes() {
    final buffer = Uint8List(payloadSize);
    final byteData = ByteData.sublistView(buffer);

    buffer[0] = AuthExchangeSubtype.rekeyConfirm.code; // 0x13
    byteData.setUint16(1, targetEpoch, Endian.big);
    buffer.setRange(3, 19, sessionId);
    buffer.setRange(19, 51, confirmMac);

    return buffer;
  }

  /// Deserializes exact 51-byte wire frame.
  factory RekeyConfirmPayload.fromBytes(Uint8List bytes) {
    if (bytes.length != payloadSize) {
      throw FormatException(
        'Invalid RekeyConfirmPayload length: expected $payloadSize bytes, got ${bytes.length}',
      );
    }
    if (bytes[0] != AuthExchangeSubtype.rekeyConfirm.code) {
      throw FormatException(
        'Invalid subtype for RekeyConfirmPayload: expected 0x13, got 0x${bytes[0].toRadixString(16)}',
      );
    }

    final byteData = ByteData.sublistView(bytes);
    final targetEpoch = byteData.getUint16(1, Endian.big);
    final sessionId = Uint8List.fromList(bytes.sublist(3, 19));
    final confirmMac = Uint8List.fromList(bytes.sublist(19, 51));

    return RekeyConfirmPayload(
      targetEpoch: targetEpoch,
      sessionId: sessionId,
      confirmMac: confirmMac,
    );
  }
}

/// Helper utility to compute canonical rekey transcripts and challenge hashes.
class RekeyTranscriptHelper {
  /// Computes SHA-256(M_rekey_init || sig_init) (32 bytes).
  static Uint8List computeInitiatorChallengeHash({
    required Uint8List mRekeyInit,
    required Uint8List sigInit,
  }) {
    final buffer = Uint8List(mRekeyInit.length + sigInit.length);
    buffer.setRange(0, mRekeyInit.length, mRekeyInit);
    buffer.setRange(mRekeyInit.length, buffer.length, sigInit);
    final digest = crypto.sha256.convert(buffer);
    return Uint8List.fromList(digest.bytes);
  }

  /// Computes the canonical 32-byte H_rekey_transcript from the exact 502-byte transcript.
  /// Rekey Transcript = M_rekey_init (169B) || Sig_Init (64B) || M_rekey_resp (205B) || Sig_Resp (64B) = 502 bytes.
  static Uint8List computeTranscriptHash({
    required Uint8List mRekeyInit,
    required Uint8List sigInit,
    required Uint8List mRekeyResp,
    required Uint8List sigResp,
  }) {
    const expectedSize = 502;
    final totalSize =
        mRekeyInit.length + sigInit.length + mRekeyResp.length + sigResp.length;
    if (totalSize != expectedSize) {
      throw ArgumentError(
        'Invalid rekey transcript length: expected $expectedSize bytes, got $totalSize bytes',
      );
    }

    final buffer = Uint8List(expectedSize);
    int offset = 0;

    buffer.setRange(offset, offset + mRekeyInit.length, mRekeyInit);
    offset += mRekeyInit.length;

    buffer.setRange(offset, offset + sigInit.length, sigInit);
    offset += sigInit.length;

    buffer.setRange(offset, offset + mRekeyResp.length, mRekeyResp);
    offset += mRekeyResp.length;

    buffer.setRange(offset, offset + sigResp.length, sigResp);

    final digest = crypto.sha256.convert(buffer);
    return Uint8List.fromList(digest.bytes);
  }
}
