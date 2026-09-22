import 'dart:typed_data';

import 'package:silosend_datasharing_app/domain/protocol/silosend_packet.dart';

/// Lifecycle state of a cryptographic session between two devices.
enum SessionState {
  disconnected,
  connecting,
  handshaking,
  connected,
  secured,
  closing,
  closed,
}

/// Abstract contract for an end-to-end authenticated, encrypted communication session.
///
/// Ensures privacy across direct links as well as multi-hop mesh relays.
abstract class SecureSession {
  /// Unique session identifier agreed upon during handshake.
  String get sessionId;

  /// Verified remote device identity.
  String get remoteDeviceId;

  /// Current lifecycle state of the session.
  SessionState get state;

  /// Whether the session is actively secured and ready to exchange encrypted data.
  bool get isEstablished => state == SessionState.secured;

  /// Encrypts and authenticates [plaintext] with the session's forward-secure key.
  Future<Uint8List> encryptPayload(
    Uint8List plaintext, {
    Uint8List? associatedData,
  });

  /// Decrypts and verifies the integrity of [ciphertext].
  Future<Uint8List> decryptPayload(
    Uint8List ciphertext, {
    Uint8List? associatedData,
  });

  /// Sends an encrypted, authenticated packet over the secure channel.
  Future<void> sendEncryptedPacket(SiloSendPacket packet);

  /// Reactive stream of decrypted, integrity-verified application packets.
  Stream<SiloSendPacket> get incomingDecryptedPackets;

  /// Gracefully tears down the session and securely zeroes keys from memory.
  Future<void> terminate();
}
