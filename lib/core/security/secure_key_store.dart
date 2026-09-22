import 'dart:typed_data';

/// Abstract contract for secure persistence of device private cryptographic key seeds.
///
/// On Android, implementations should bind to the hardware-backed Android KeyStore
/// (using MasterKey with AES-256-GCM in TEE/StrongBox).
/// In unit/widget tests and pure Dart environments, in-memory implementations are used.
abstract class SecureKeyStore {
  /// Loads the stored 32-byte Ed25519 private seed, or null if uninitialized.
  Future<Uint8List?> loadIdentitySeed();

  /// Persists the 32-byte Ed25519 private seed under hardware-backed or secure storage.
  Future<void> saveIdentitySeed(Uint8List seed);

  /// Securely clears the persisted private seed.
  Future<void> clearIdentitySeed();
}

/// In-memory implementation of [SecureKeyStore] used for automated tests and isolated runs.
class InMemorySecureKeyStore implements SecureKeyStore {
  Uint8List? _seed;

  @override
  Future<Uint8List?> loadIdentitySeed() async {
    if (_seed == null) return null;
    return Uint8List.fromList(_seed!);
  }

  @override
  Future<void> saveIdentitySeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(
        seed.length,
        'seed',
        'Must be exactly 32 bytes',
      );
    }
    _seed = Uint8List.fromList(seed);
  }

  @override
  Future<void> clearIdentitySeed() async {
    if (_seed != null) {
      _seed!.fillRange(0, _seed!.length, 0);
      _seed = null;
    }
  }
}
