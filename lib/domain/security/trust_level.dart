/// Trust and authentication status for a peer device identity in Vayu.
///
/// In accordance with the Vayu security model:
/// - A signature proves possession of the private key corresponding to the presented public key
///   and that this key signed the claimed device ID.
/// - It does NOT prove that a freshly generated device ID intrinsically belongs to that public key on first contact.
enum TrustLevel {
  /// First contact with an unseen device ID.
  /// The payload is encrypted against passive eavesdroppers, but is vulnerable
  /// to an active initial Man-in-the-Middle (MITM) attacker substituting keys.
  unverifiedTOFU,

  /// Subsequent contact with a known device ID whose presented public key matches
  /// the key previously recorded in the local trust store.
  /// Protects against subsequent impersonation.
  trustedTOFU,

  /// Both users have manually compared and confirmed the Short Authentication String (SAS)
  /// across an independent, out-of-band physical channel.
  /// Active initial MITM attack is mitigated (collision probability <= 10^-6 per attempt).
  sasVerified,

  /// Out-of-band physical exchange occurred via NFC or QR code carrying a valid
  /// cryptographic key commitment (SHA-256 of public key and pairing secret).
  /// Mathematically proves the key belongs to the physical peer.
  nfcAuthenticated,

  /// CRITICAL SECURITY CONFLICT: A known device ID presents a public key that differs
  /// from the public key stored in the local trust store.
  /// Traffic is halted immediately to protect against active impersonation or key replacement.
  keyConflict,
}

/// Plain-language label for [TrustLevel]; matches `TrustLabel` in the UI.
extension TrustLevelDisplay on TrustLevel {
  String get displayLabel {
    switch (this) {
      case TrustLevel.unverifiedTOFU:
        return 'New device';
      case TrustLevel.trustedTOFU:
        return 'Known device';
      case TrustLevel.sasVerified:
        return 'Verified';
      case TrustLevel.nfcAuthenticated:
        return 'Verified';
      case TrustLevel.keyConflict:
        return 'Security warning';
    }
  }
}
