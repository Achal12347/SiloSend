import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vayu/core/errors/app_error.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/security/trust_level.dart';

/// Stored record representing a known peer's cryptographic identity and trust status.
class PeerTrustRecord {
  final String deviceIdHex;
  final Uint8List identityPubKey;
  final TrustLevel trustLevel;
  final DateTime firstSeen;
  final DateTime lastSeen;

  const PeerTrustRecord({
    required this.deviceIdHex,
    required this.identityPubKey,
    required this.trustLevel,
    required this.firstSeen,
    required this.lastSeen,
  });

  PeerTrustRecord copyWith({TrustLevel? trustLevel, DateTime? lastSeen}) {
    return PeerTrustRecord(
      deviceIdHex: deviceIdHex,
      identityPubKey: identityPubKey,
      trustLevel: trustLevel ?? this.trustLevel,
      firstSeen: firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

/// Exception thrown when a known device ID presents a different Ed25519 public key.
class IdentityKeyConflictException extends SecurityError {
  final String deviceIdHex;
  final String existingKeyHex;
  final String presentedKeyHex;

  IdentityKeyConflictException({
    required this.deviceIdHex,
    required this.existingKeyHex,
    required this.presentedKeyHex,
  }) : super(
         'CRITICAL: Peer identity key conflict for device $deviceIdHex. Potential Man-in-the-Middle attack or device reset.',
       );
}

/// Exception thrown when out-of-band NFC commitment verification fails.
class NfcCommitmentMismatchException extends SecurityError {
  final String deviceIdHex;
  final String expectedCommitmentHex;
  final String presentedCommitmentHex;

  NfcCommitmentMismatchException({
    required this.deviceIdHex,
    required this.expectedCommitmentHex,
    required this.presentedCommitmentHex,
  }) : super(
         'CRITICAL: NFC cryptographic commitment verification failed for device $deviceIdHex. '
         'Presented identity key does not match out-of-band NFC tap commitment.',
       );
}

/// Manages Trust-On-First-Use (TOFU), SAS verifications, and NFC cryptographic commitments.
class PeerTrustStore {
  final Map<String, PeerTrustRecord> _records = {};

  /// Current in-memory trust records indexed by lowercase device ID hex.
  Map<String, PeerTrustRecord> get records => Map.unmodifiable(_records);

  /// Retrieves the recorded trust level for a given device ID, or null if unknown.
  TrustLevel? getTrustLevel(String deviceIdHex) {
    return _records[deviceIdHex.toLowerCase()]?.trustLevel;
  }

  /// Retrieves the trust record for a given [deviceIdHex], if known.
  Future<PeerTrustRecord?> getPeerTrust(String deviceIdHex) async {
    return _records[deviceIdHex.toLowerCase()];
  }

  /// Evaluates and updates trust status for a peer presenting an Ed25519 public key.
  ///
  /// - First contact: Records peer as `unverifiedTOFU` (or `nfcAuthenticated` if commitment matches).
  /// - Subsequent contact: If public key matches, retains/promotes to `trustedTOFU` (or `nfcAuthenticated`).
  /// - Key change conflict: If public key does NOT match stored key, records `keyConflict`
  ///   and throws [IdentityKeyConflictException].
  /// - NFC commitment mismatch: Throws [NfcCommitmentMismatchException], rejects authentication,
  ///   and strictly avoids TOFU fallback.
  Future<TrustLevel> evaluatePeer({
    required String deviceIdHex,
    required Uint8List presentedIdentityPubKey,
    Uint8List? nfcCommitment,
    Uint8List? pairingSecret,
  }) async {
    final key = deviceIdHex.toLowerCase();
    final existing = _records[key];
    final now = DateTime.now();

    // 1. If an NFC commitment is provided, strictly verify it.
    // Mismatch or missing secret MUST throw and reject; NEVER fall back to TOFU!
    bool nfcVerified = false;
    if (nfcCommitment != null) {
      if (pairingSecret == null) {
        throw NfcCommitmentMismatchException(
          deviceIdHex: deviceIdHex,
          expectedCommitmentHex: 'none (missing secret)',
          presentedCommitmentHex: _toHex(nfcCommitment),
        );
      }
      final expectedCommitment = computeNfcCommitment(
        ed25519PubKey: presentedIdentityPubKey,
        pairingSecret: pairingSecret,
      );
      if (!_bytesEqual(expectedCommitment, nfcCommitment)) {
        final expectedHex = _toHex(expectedCommitment);
        final presentedHex = _toHex(nfcCommitment);
        AppLogger.error(
          'PeerTrustStore',
          'NFC commitment mismatch for device $deviceIdHex! Expected: $expectedHex, Provided: $presentedHex',
        );
        throw NfcCommitmentMismatchException(
          deviceIdHex: deviceIdHex,
          expectedCommitmentHex: expectedHex,
          presentedCommitmentHex: presentedHex,
        );
      }
      nfcVerified = true;
      AppLogger.info(
        'PeerTrustStore',
        'Peer $deviceIdHex authenticated via valid NFC commitment',
      );
    }

    if (existing == null) {
      // First contact
      final initialLevel = nfcVerified
          ? TrustLevel.nfcAuthenticated
          : TrustLevel.unverifiedTOFU;

      _records[key] = PeerTrustRecord(
        deviceIdHex: key,
        identityPubKey: Uint8List.fromList(presentedIdentityPubKey),
        trustLevel: initialLevel,
        firstSeen: now,
        lastSeen: now,
      );

      return initialLevel;
    }

    // Repeated contact: Check for identity key conflict
    if (!_bytesEqual(existing.identityPubKey, presentedIdentityPubKey)) {
      _records[key] = existing.copyWith(
        trustLevel: TrustLevel.keyConflict,
        lastSeen: now,
      );

      final existingHex = _toHex(existing.identityPubKey);
      final presentedHex = _toHex(presentedIdentityPubKey);

      AppLogger.error(
        'PeerTrustStore',
        'Identity key conflict detected for device $deviceIdHex! Stored: $existingHex, Presented: $presentedHex',
      );

      throw IdentityKeyConflictException(
        deviceIdHex: deviceIdHex,
        existingKeyHex: existingHex,
        presentedKeyHex: presentedHex,
      );
    }

    // Same key observed again
    TrustLevel effectiveLevel = existing.trustLevel;
    if (nfcVerified) {
      effectiveLevel = TrustLevel.nfcAuthenticated;
    } else if (effectiveLevel == TrustLevel.unverifiedTOFU) {
      effectiveLevel = TrustLevel.trustedTOFU;
    }

    _records[key] = existing.copyWith(
      trustLevel: effectiveLevel,
      lastSeen: now,
    );

    return effectiveLevel;
  }

  /// Updates the trust level for a verified peer (e.g. after user confirms SAS match).
  Future<void> updateTrustLevel(String deviceIdHex, TrustLevel newLevel) async {
    final key = deviceIdHex.toLowerCase();
    final existing = _records[key];
    if (existing == null) {
      throw StateError(
        'Cannot update trust level for unknown peer $deviceIdHex',
      );
    }

    _records[key] = existing.copyWith(
      trustLevel: newLevel,
      lastSeen: DateTime.now(),
    );

    AppLogger.info(
      'PeerTrustStore',
      'Updated trust level for $deviceIdHex to $newLevel',
    );
  }

  /// Promotes a peer to [TrustLevel.sasVerified] after successful out-of-band SAS code confirmation.
  Future<void> promoteToSasVerified(
    String deviceIdHex,
    Uint8List identityPubKey,
  ) async {
    final key = deviceIdHex.toLowerCase();
    final existing = _records[key];
    final now = DateTime.now();

    if (existing == null) {
      _records[key] = PeerTrustRecord(
        deviceIdHex: key,
        identityPubKey: Uint8List.fromList(identityPubKey),
        trustLevel: TrustLevel.sasVerified,
        firstSeen: now,
        lastSeen: now,
      );
    } else {
      _records[key] = existing.copyWith(
        trustLevel: TrustLevel.sasVerified,
        lastSeen: now,
      );
    }

    AppLogger.info(
      'PeerTrustStore',
      'Peer $deviceIdHex promoted to SAS Verified',
    );
  }

  /// Computes the standard 32-byte cryptographic NFC commitment:
  /// SHA-256("SiloSend-NFC-Commitment-v1:" || ed25519PubKey (32B) || pairingSecret (16B))
  static Uint8List computeNfcCommitment({
    required Uint8List ed25519PubKey,
    required Uint8List pairingSecret,
  }) {
    if (ed25519PubKey.length != 32) {
      throw ArgumentError.value(
        ed25519PubKey.length,
        'ed25519PubKey',
        'Must be 32 bytes',
      );
    }
    if (pairingSecret.length != 16) {
      throw ArgumentError.value(
        pairingSecret.length,
        'pairingSecret',
        'Must be 16 bytes',
      );
    }

    final prefix = 'SiloSend-NFC-Commitment-v1:'.codeUnits;
    final buffer = Uint8List(
      prefix.length + ed25519PubKey.length + pairingSecret.length,
    );
    buffer.setRange(0, prefix.length, prefix);
    buffer.setRange(prefix.length, prefix.length + 32, ed25519PubKey);
    buffer.setRange(prefix.length + 32, buffer.length, pairingSecret);

    final digest = crypto.sha256.convert(buffer);
    return Uint8List.fromList(digest.bytes);
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _toHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
