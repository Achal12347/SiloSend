import 'dart:math';
import 'dart:typed_data';

class KeyExchange {
  Uint8List generateSessionKey({int length = 32}) {
    final rand = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => rand.nextInt(256)),
    );
  }
}
