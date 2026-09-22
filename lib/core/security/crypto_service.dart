import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:silosend_datasharing_app/domain/security/crypto_identity_keypair.dart';

/// Comprehensive cryptographic service providing reviewed, standard cryptographic primitives
/// for device authentication (Ed25519), ephemeral key exchange (X25519),
/// session key derivation (HKDF-SHA256), and authenticated encryption (AES-256-GCM AEAD).
class CryptoService {
  final Ed25519 _ed25519 = Ed25519();
  final X25519 _x25519 = X25519();
  final AesGcm _aesGcm256 = AesGcm.with256bits();

  /// Generates a persistent Ed25519 identity keypair using a cryptographically secure random 32-byte seed.
  Future<CryptoIdentityKeypair> generateIdentityKeypair() async {
    final random = Random.secure();
    final seed = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      seed[i] = random.nextInt(256);
    }

    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();

    return CryptoIdentityKeypair(
      publicKey: Uint8List.fromList(publicKey.bytes),
      privateKeySeed: seed,
    );
  }

  /// Signs [message] using an Ed25519 private [seed], producing an exact 64-byte signature.
  Future<Uint8List> signEd25519({
    required Uint8List message,
    required Uint8List privateKeySeed,
  }) async {
    if (privateKeySeed.length != 32) {
      throw ArgumentError.value(
        privateKeySeed.length,
        'privateKeySeed',
        'Seed must be exactly 32 bytes',
      );
    }
    final keyPair = await _ed25519.newKeyPairFromSeed(privateKeySeed);
    final signature = await _ed25519.sign(message, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  /// Verifies that [signature] (64 bytes) was produced by the Ed25519 [publicKey] (32 bytes) over [message].
  Future<bool> verifyEd25519({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async {
    if (publicKey.length != 32) return false;
    if (signature.length != 64) return false;

    try {
      final ed25519PublicKey = SimplePublicKey(
        publicKey,
        type: KeyPairType.ed25519,
      );
      final sig = Signature(signature, publicKey: ed25519PublicKey);
      return await _ed25519.verify(message, signature: sig);
    } catch (_) {
      return false;
    }
  }

  /// Generates a fresh ephemeral X25519 keypair for Perfect Forward Secrecy.
  Future<SimpleKeyPair> generateEphemeralX25519Keypair() async {
    return await _x25519.newKeyPair();
  }

  /// Extracts the 32-byte public key point from an ephemeral X25519 [keyPair].
  Future<Uint8List> extractX25519PublicKey(SimpleKeyPair keyPair) async {
    final pubKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(pubKey.bytes);
  }

  /// Computes the 32-byte shared secret via X25519 ECDH Diffie-Hellman.
  Future<Uint8List> computeSharedSecret({
    required SimpleKeyPair localKeyPair,
    required Uint8List remotePublicKeyBytes,
  }) async {
    if (remotePublicKeyBytes.length != 32) {
      throw ArgumentError.value(
        remotePublicKeyBytes.length,
        'remotePublicKeyBytes',
        'Remote X25519 public key must be exactly 32 bytes',
      );
    }
    final remotePublicKey = SimplePublicKey(
      remotePublicKeyBytes,
      type: KeyPairType.x25519,
    );

    final secretKey = await _x25519.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: remotePublicKey,
    );

    final secretBytes = await secretKey.extractBytes();
    return Uint8List.fromList(secretBytes);
  }

  /// Derives all session keys from the X25519 [sharedSecret], random [salt], and [transcriptHash]
  /// in strict accordance with the audited Phase 6 specification.
  Future<DerivedSessionKeys> deriveSessionKeys({
    required Uint8List sharedSecret,
    required Uint8List initiatorNonce,
    required Uint8List responderNonce,
    required Uint8List sessionId,
    required Uint8List transcriptHash,
  }) async {
    if (sharedSecret.length != 32) {
      throw ArgumentError.value(
        sharedSecret.length,
        'sharedSecret',
        'Must be 32 bytes',
      );
    }
    if (initiatorNonce.length != 32 || responderNonce.length != 32) {
      throw ArgumentError('Nonces must each be exactly 32 bytes');
    }
    if (sessionId.length != 16) {
      throw ArgumentError('Session ID must be exactly 16 bytes');
    }
    if (transcriptHash.length != 32) {
      throw ArgumentError('Transcript hash must be exactly 32 bytes');
    }

    // 1. Salt = Nonce_A (32B) || Nonce_B (32B) = 64 bytes
    final salt = Uint8List(64);
    salt.setRange(0, 32, initiatorNonce);
    salt.setRange(32, 64, responderNonce);

    // 2. BaseInfo = "SiloSend-v1-Session:" (20B) || SessionId (16B) || H_transcript (32B) = 68 bytes
    final basePrefix = 'SiloSend-v1-Session:'.codeUnits; // 20 bytes
    final baseInfo = Uint8List(
      basePrefix.length + sessionId.length + transcriptHash.length,
    );
    baseInfo.setRange(0, basePrefix.length, basePrefix);
    baseInfo.setRange(basePrefix.length, basePrefix.length + 16, sessionId);
    baseInfo.setRange(basePrefix.length + 16, baseInfo.length, transcriptHash);

    // 3. Helper to run HKDF-Expand with distinct domain labels
    Future<Uint8List> expand(
      int labelByte,
      String label,
      int outputLength,
    ) async {
      final labelBytes = label.codeUnits;
      final info = Uint8List(baseInfo.length + 1 + labelBytes.length);
      info.setRange(0, baseInfo.length, baseInfo);
      info[baseInfo.length] = labelByte;
      info.setRange(baseInfo.length + 1, info.length, labelBytes);

      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: outputLength);

      final derivedSecretKey = await hkdf.deriveKey(
        secretKey: SecretKey(sharedSecret),
        nonce: salt,
        info: info,
      );

      final bytes = await derivedSecretKey.extractBytes();
      return Uint8List.fromList(bytes);
    }

    final keyInitToResp = await expand(0x01, 'init-to-resp-aes', 32);
    final keyRespToInit = await expand(0x02, 'resp-to-init-aes', 32);
    final saltInitNonce = await expand(0x03, 'init-nonce-salt', 4);
    final saltRespNonce = await expand(0x04, 'resp-nonce-salt', 4);
    final confirmKey = await expand(0x05, 'session-confirm-mac', 32);
    final sasKey = await expand(0x06, 'short-auth-string', 16);

    return DerivedSessionKeys(
      keyInitToResp: keyInitToResp,
      keyRespToInit: keyRespToInit,
      saltInitNonce: saltInitNonce,
      saltRespNonce: saltRespNonce,
      confirmKey: confirmKey,
      sasKey: sasKey,
    );
  }

  /// Computes a confirmation HMAC: HMAC-SHA256(confirmKey, label || transcriptHash)
  Future<Uint8List> computeConfirmMac({
    required Uint8List confirmKey,
    required String label,
    required Uint8List transcriptHash,
  }) async {
    final labelBytes = label.codeUnits;
    final message = Uint8List(labelBytes.length + transcriptHash.length);
    message.setRange(0, labelBytes.length, labelBytes);
    message.setRange(labelBytes.length, message.length, transcriptHash);

    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      message,
      secretKey: SecretKey(confirmKey),
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// Derives fresh session keys for a new key epoch (Epoch E+1) via HKDF-SHA256.
  ///
  /// Cryptographic Binding:
  /// - IKM = SharedSecret (32B) || PreviousEpochConfirmKey (32B) = 64 bytes
  /// - Salt = InitiatorNonce (32B) || ResponderNonce (32B) = 64 bytes
  /// - BaseInfo = "SiloSend-v1-Rekey-Epoch-$targetEpoch:" || SessionId (16B) || H_rekey_transcript (32B)
  Future<DerivedSessionKeys> deriveRekeySessionKeys({
    required Uint8List sharedSecret, // 32 bytes X25519
    required Uint8List prevConfirmKey, // 32 bytes K_confirm^(E)
    required Uint8List initiatorNonce, // 32 bytes
    required Uint8List responderNonce, // 32 bytes
    required Uint8List sessionId, // 16 bytes
    required int targetEpoch,
    required Uint8List transcriptHash, // 32 bytes
  }) async {
    if (sharedSecret.length != 32) {
      throw ArgumentError('Shared secret must be exactly 32 bytes');
    }
    if (prevConfirmKey.length != 32) {
      throw ArgumentError('Previous confirm key must be exactly 32 bytes');
    }
    if (initiatorNonce.length != 32 || responderNonce.length != 32) {
      throw ArgumentError('Nonces must be exactly 32 bytes each');
    }
    if (sessionId.length != 16) {
      throw ArgumentError('Session ID must be exactly 16 bytes');
    }
    if (transcriptHash.length != 32) {
      throw ArgumentError('Transcript hash must be exactly 32 bytes');
    }

    // 1. IKM = SharedSecret (32B) || prevConfirmKey (32B) = 64 bytes
    final ikm = Uint8List(64);
    ikm.setRange(0, 32, sharedSecret);
    ikm.setRange(32, 64, prevConfirmKey);

    // 2. Salt = Nonce_A (32B) || Nonce_B (32B) = 64 bytes
    final salt = Uint8List(64);
    salt.setRange(0, 32, initiatorNonce);
    salt.setRange(32, 64, responderNonce);

    // 3. BaseInfo = "SiloSend-v1-Rekey-Epoch-$targetEpoch:" || SessionId (16B) || H_transcript (32B)
    final prefixString = 'SiloSend-v1-Rekey-Epoch-$targetEpoch:';
    final basePrefix = utf8.encode(prefixString);
    final baseInfo = Uint8List(
      basePrefix.length + sessionId.length + transcriptHash.length,
    );
    baseInfo.setRange(0, basePrefix.length, basePrefix);
    baseInfo.setRange(basePrefix.length, basePrefix.length + 16, sessionId);
    baseInfo.setRange(basePrefix.length + 16, baseInfo.length, transcriptHash);

    Future<Uint8List> expand(
      int labelByte,
      String label,
      int outputLength,
    ) async {
      final labelBytes = utf8.encode(label);
      final info = Uint8List(baseInfo.length + 1 + labelBytes.length);
      info.setRange(0, baseInfo.length, baseInfo);
      info[baseInfo.length] = labelByte;
      info.setRange(baseInfo.length + 1, info.length, labelBytes);

      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: outputLength);
      final derivedSecretKey = await hkdf.deriveKey(
        secretKey: SecretKey(ikm),
        nonce: salt,
        info: info,
      );
      final bytes = await derivedSecretKey.extractBytes();
      return Uint8List.fromList(bytes);
    }

    final keyInitToResp = await expand(0x01, 'init-to-resp-aes', 32);
    final keyRespToInit = await expand(0x02, 'resp-to-init-aes', 32);
    final saltInitNonce = await expand(0x03, 'init-nonce-salt', 4);
    final saltRespNonce = await expand(0x04, 'resp-nonce-salt', 4);
    final confirmKey = await expand(0x05, 'rekey-confirm-mac', 32);
    final sasKey = await expand(0x06, 'short-auth-string', 16);

    // Clean up temporary IKM
    CryptoService.secureWipe(ikm);

    return DerivedSessionKeys(
      keyInitToResp: keyInitToResp,
      keyRespToInit: keyRespToInit,
      saltInitNonce: saltInitNonce,
      saltRespNonce: saltRespNonce,
      confirmKey: confirmKey,
      sasKey: sasKey,
    );
  }

  /// Computes the authentication MAC binding a RekeyInit frame to the previous epoch:
  /// HMAC-SHA256(prevConfirmKey, "SiloSend-v1-RekeyInit-MAC:" || SessionId || TargetEpoch || ephPubKey || Nonce)
  Future<Uint8List> computeRekeyPrevEpochMac({
    required Uint8List prevConfirmKey,
    required Uint8List sessionId,
    required int targetEpoch,
    required Uint8List ephemeralPubKey,
    required Uint8List nonce,
  }) async {
    final domainTag = utf8.encode('SiloSend-v1-RekeyInit-MAC:'); // 26 bytes
    final message = Uint8List(
      domainTag.length + 16 + 2 + ephemeralPubKey.length + nonce.length,
    );
    int offset = 0;
    message.setRange(offset, offset + domainTag.length, domainTag);
    offset += domainTag.length;

    message.setRange(offset, offset + 16, sessionId);
    offset += 16;

    final epochData = ByteData(2)..setUint16(0, targetEpoch, Endian.big);
    message.setRange(offset, offset + 2, epochData.buffer.asUint8List());
    offset += 2;

    message.setRange(offset, offset + ephemeralPubKey.length, ephemeralPubKey);
    offset += ephemeralPubKey.length;

    message.setRange(offset, offset + nonce.length, nonce);

    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      message,
      secretKey: SecretKey(prevConfirmKey),
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// Encrypts [plaintext] using AES-256-GCM AEAD with the exact 76-byte [aad].
  /// Returns a record containing (ciphertext, 16-byte authTag).
  Future<({Uint8List ciphertext, Uint8List authTag})> encryptAead({
    required Uint8List plaintext,
    required Uint8List secretKeyBytes,
    required Uint8List nonce, // 12 bytes
    required Uint8List aad, // 76 bytes
  }) async {
    if (secretKeyBytes.length != 32) {
      throw ArgumentError.value(
        secretKeyBytes.length,
        'secretKeyBytes',
        'Must be 32 bytes',
      );
    }
    if (nonce.length != 12) {
      throw ArgumentError.value(nonce.length, 'nonce', 'Must be 12 bytes');
    }
    if (aad.length != 76) {
      throw ArgumentError.value(aad.length, 'aad', 'Must be exactly 76 bytes');
    }

    final secretBox = await _aesGcm256.encrypt(
      plaintext,
      secretKey: SecretKey(secretKeyBytes),
      nonce: nonce,
      aad: aad,
    );

    return (
      ciphertext: Uint8List.fromList(secretBox.cipherText),
      authTag: Uint8List.fromList(secretBox.mac.bytes),
    );
  }

  /// Decrypts [ciphertext] and authenticates [authTag] using AES-256-GCM AEAD with exact 76-byte [aad].
  Future<Uint8List> decryptAead({
    required Uint8List ciphertext,
    required Uint8List authTag,
    required Uint8List secretKeyBytes,
    required Uint8List nonce, // 12 bytes
    required Uint8List aad, // 76 bytes
  }) async {
    if (secretKeyBytes.length != 32) {
      throw ArgumentError.value(
        secretKeyBytes.length,
        'secretKeyBytes',
        'Must be 32 bytes',
      );
    }
    if (nonce.length != 12) {
      throw ArgumentError.value(nonce.length, 'nonce', 'Must be 12 bytes');
    }
    if (authTag.length != 16) {
      throw ArgumentError.value(authTag.length, 'authTag', 'Must be 16 bytes');
    }
    if (aad.length != 76) {
      throw ArgumentError.value(aad.length, 'aad', 'Must be exactly 76 bytes');
    }

    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(authTag));

    final decrypted = await _aesGcm256.decrypt(
      secretBox,
      secretKey: SecretKey(secretKeyBytes),
      aad: aad,
    );

    return Uint8List.fromList(decrypted);
  }

  /// Constructs the canonical 76-byte AEAD Associated Authenticated Data (AAD).
  ///
  /// Composition:
  /// - Header_immutable: 48 bytes (magic:2, ver:1, type:1, id:8, src:16, dest:16, payloadLength:4)
  /// - SessionId: 16 bytes
  /// - AEAD Nonce: 12 bytes (4B salt + 8B sequenceNumber)
  /// Total = 76 bytes.
  static Uint8List constructAad({
    required int magic1,
    required int magic2,
    required int protocolVersion,
    required int packetTypeCode,
    required int packetId,
    required Uint8List sourceDeviceId,
    required Uint8List destinationDeviceId,
    required int payloadLength,
    required Uint8List sessionId,
    required Uint8List aeadNonce,
  }) {
    if (sourceDeviceId.length != 16 || destinationDeviceId.length != 16) {
      throw ArgumentError('Source and Destination device IDs must be 16 bytes');
    }
    if (sessionId.length != 16) {
      throw ArgumentError('Session ID must be 16 bytes');
    }
    if (aeadNonce.length != 12) {
      throw ArgumentError('AEAD Nonce must be 12 bytes');
    }

    const totalLength = 76;
    final buffer = Uint8List(totalLength);
    final byteData = ByteData.sublistView(buffer);

    // Header_immutable (48 bytes)
    buffer[0] = magic1;
    buffer[1] = magic2;
    buffer[2] = protocolVersion;
    buffer[3] = packetTypeCode;
    byteData.setInt64(4, packetId, Endian.big);
    buffer.setRange(12, 28, sourceDeviceId);
    buffer.setRange(28, 44, destinationDeviceId);
    byteData.setUint32(44, payloadLength, Endian.big);

    // SessionId (16 bytes)
    buffer.setRange(48, 64, sessionId);

    // AEAD Nonce (12 bytes)
    buffer.setRange(64, 76, aeadNonce);

    return buffer;
  }

  /// Best-effort in-memory buffer zeroing. Overwrites the mutable backing byte array with zeros.
  /// Note: As documented, this cannot guarantee physical RAM erasure across garbage collector copies.
  static void secureWipe(Uint8List buffer) {
    buffer.fillRange(0, buffer.length, 0);
  }
}

/// Container for all keys derived from the HKDF-SHA256 handshake expansion.
class DerivedSessionKeys {
  final Uint8List keyInitToResp; // 32 bytes
  final Uint8List keyRespToInit; // 32 bytes
  final Uint8List saltInitNonce; // 4 bytes
  final Uint8List saltRespNonce; // 4 bytes
  final Uint8List confirmKey; // 32 bytes
  final Uint8List sasKey; // 16 bytes

  DerivedSessionKeys({
    required this.keyInitToResp,
    required this.keyRespToInit,
    required this.saltInitNonce,
    required this.saltRespNonce,
    required this.confirmKey,
    required this.sasKey,
  });

  /// Best-effort zeroing of all key material in this container.
  void wipe() {
    CryptoService.secureWipe(keyInitToResp);
    CryptoService.secureWipe(keyRespToInit);
    CryptoService.secureWipe(saltInitNonce);
    CryptoService.secureWipe(saltRespNonce);
    CryptoService.secureWipe(confirmKey);
    CryptoService.secureWipe(sasKey);
  }
}
