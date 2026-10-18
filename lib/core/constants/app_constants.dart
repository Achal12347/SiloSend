/// Core application constants for Vayu.
class AppConstants {
  AppConstants._();

  /// User-facing application name.
  static const String appName = 'Vayu';

  /// Application identifier.
  static const String applicationId = 'com.achyrio.vayu';

  /// Protocol version for Vayu device-to-device communication.
  static const int protocolVersion = 1;

  /// Optional protocol features this build understands, advertised in the
  /// handshake. Older builds send none and ignore the field, so a feature is
  /// used only when both sides list it. The handshake is not authenticated:
  /// a forged list can only downgrade to the older, always-safe behaviour.
  static const Set<String> protocolFeatures = {
    featureBatchOffer,
    featureLateHash,
  };

  /// One batch offer and one consent for several files (packet 0x15/0x16).
  static const String featureBatchOffer = 'batch-v1';

  /// Offer first, SHA-256 later (packet 0x17): the receiver is asked at once
  /// instead of after the sender has read the whole file to hash it.
  static const String featureLateHash = 'late-hash-v1';

  /// Android minimum supported SDK version (Android 8.0 Oreo).
  static const int androidMinSdkVersion = 26;
}
