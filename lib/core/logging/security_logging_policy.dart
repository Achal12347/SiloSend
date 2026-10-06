/// Formal Vayu Security Logging Policy and Sanitization Engine.
///
/// In accordance with Vayu Privacy & Security Principles (TARGET.md §3.2, §3.3),
/// sensitive cryptographic material and user plaintext must NEVER be logged or leaked
/// to system diagnostics or logcat.
///
/// ### FORBIDDEN in Logs:
/// - Private key material (Ed25519 private seeds, private scalar bytes)
/// - Symmetric secret keys (AES-256 session keys, HKDF derived keys, confirmation MAC keys)
/// - Ephemeral ECDH shared secrets (X25519 outputs)
/// - Raw nonces / initialization vectors
/// - Plaintext user data payloads (messages, file contents)
///
/// ### PERMITTED in Logs:
/// - Public key fingerprints (e.g. `Vayu-Ed25519-Identity-v1:a1b2...`)
/// - Ephemeral public keys (publicly exchanged over the wire)
/// - Monotonic packet sequence numbers and packet IDs
/// - Session IDs and Device UUIDs
/// - Protocol state transitions (`connected`, `handshaking`, `secured`)
/// - Short Authentication Strings (SAS) specifically intended for visual/verbal user inspection
class SecurityLoggingPolicy {
  SecurityLoggingPolicy._();

  static final RegExp _sensitivePattern = RegExp(
    r'(privateKeySeed|privateKey|private_seed|secretKey|sharedSecret|shared_secret|masterSecret|confirmKey|txKey|rxKey|sessionKey|rawNonce|plaintextPayload)\s*[:=]\s*([^\s,;]+)',
    caseSensitive: false,
  );

  static final RegExp _hexSecretPattern = RegExp(
    r'\b(seed|private|secret|shared)\s*[:=]\s*([0-9a-fA-F]{64,128})\b',
    caseSensitive: false,
  );

  /// Sanitizes an application log message, redacting any accidental or debug
  /// key disclosures with `[REDACTED_SECRET]`.
  static String sanitize(String message) {
    if (message.isEmpty) return message;

    var sanitized = message.replaceAllMapped(_sensitivePattern, (match) {
      final keyName = match.group(1);
      return '$keyName: [REDACTED_SECRET]';
    });

    sanitized = sanitized.replaceAllMapped(_hexSecretPattern, (match) {
      final keyName = match.group(1);
      return '$keyName: [REDACTED_SECRET]';
    });

    return sanitized;
  }

  /// Checks whether a given string contains patterns that resemble sensitive key labels.
  static bool containsSensitivePatterns(String text) {
    return _sensitivePattern.hasMatch(text) || _hexSecretPattern.hasMatch(text);
  }

  /// Formats a public key fingerprint safely for diagnostic logging.
  static String formatPublicFingerprint(
    String fingerprint, {
    int prefixLength = 24,
  }) {
    if (fingerprint.length <= prefixLength) return fingerprint;
    return '${fingerprint.substring(0, prefixLength)}...';
  }
}
