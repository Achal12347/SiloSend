import 'dart:math';
import 'dart:typed_data';

/// Phase 4 mock-only key exchange (scaffolding).
///
/// Real session key exchange will be implemented after Connection/Transport
/// is wired to encryption. For now we only generate deterministic-ish bytes
/// to unblock encryption service compilation.
class KeyExchange {
  Uint8List generateSessionKey({int length = 32}) {
    final rand = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => rand.nextInt(256)),
    );
  }
}
