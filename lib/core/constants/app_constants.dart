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
    featureLinkUpgrade,
    featureChat,
    featureHost,
    featureChatFiles,
    featureMesh,
  };

  /// One batch offer and one consent for several files (packet 0x15/0x16).
  static const String featureBatchOffer = 'batch-v1';

  /// Offer first, SHA-256 later (packet 0x17): the receiver is asked at once
  /// instead of after the sender has read the whole file to hash it.
  static const String featureLateHash = 'late-hash-v1';

  /// Moving a session found over Bluetooth onto Wi-Fi Direct (packets
  /// 0x40/0x41): the group's name and passphrase travel inside the encrypted
  /// Bluetooth session, then both phones connect over Wi-Fi.
  static const String featureLinkUpgrade = 'p2p-upgrade-v1';

  /// Text messages and receipts (packets 0x20/0x21) over the same encrypted
  /// sessions as files.
  static const String featureChat = 'chat-v1';

  /// Host & Client (packets 0x50-0x54): browse what a nearby phone hosts
  /// and download chosen files as an ordinary batch transfer.
  static const String featureHost = 'host-v1';

  /// Files sent inside a chat (packets 0x22/0x23); older builds would drop
  /// those packets, so they are only sent to peers listing this.
  static const String featureChatFiles = 'chat-files-v1';

  /// Understands mesh relay packets (0x60-0x65); whether it relays for
  /// others is its user's setting, told in each reach answer.
  static const String featureMesh = 'mesh-v1';

  /// Android minimum supported SDK version (Android 8.0 Oreo).
  static const int androidMinSdkVersion = 26;
}
