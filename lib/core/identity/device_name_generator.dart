import 'dart:typed_data';

/// Builds a readable default device name such as `Vayu-BlueFalcon-7K`.
///
/// The name is derived from the device ID, so the same install always gets
/// the same default, and two new phones almost never look alike. It is only
/// a label: trust, consent and history key on the device ID, never on this.
///
/// The word lists are separate from the SAS verification words on purpose,
/// so a device name can never be mistaken for a safety-check word.
class DeviceNameGenerator {
  DeviceNameGenerator._();

  /// Name every install used before generated names existed.
  static const String legacyDefaultName = 'Vayu-Device';

  static const List<String> _adjectives = [
    'Amber', 'Azure', 'Bold', 'Brave', 'Bright', 'Calm', 'Clever', 'Coral', //
    'Crisp', 'Dusky', 'Eager', 'Fleet', 'Gentle', 'Golden', 'Hazel', 'Ivory',
    'Jade', 'Keen', 'Lucky', 'Lunar', 'Mellow', 'Misty', 'Noble', 'Olive',
    'Quiet', 'Rapid', 'Rustic', 'Silver', 'Solar', 'Swift', 'Velvet', 'Wild',
  ];

  static const List<String> _animals = [
    'Badger', 'Bison', 'Crane', 'Dolphin', 'Eagle', 'Falcon', 'Finch', 'Fox', //
    'Gecko', 'Heron', 'Ibis', 'Jaguar', 'Koala', 'Lark', 'Lemur', 'Lynx',
    'Marten', 'Moose', 'Newt', 'Otter', 'Owl', 'Panda', 'Puffin', 'Quail',
    'Raven', 'Robin', 'Seal', 'Swan', 'Tiger', 'Viper', 'Wolf', 'Yak',
  ];

  // No 0/O or 1/I, so the suffix is easy to read aloud.
  static const String _suffixAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  /// The default name for [deviceId] (16 bytes; shorter IDs still work).
  static String forDeviceId(Uint8List deviceId) {
    int byteAt(int i) => deviceId.isEmpty ? 0 : deviceId[i % deviceId.length];
    final adjective = _adjectives[byteAt(0) % _adjectives.length];
    final animal = _animals[byteAt(1) % _animals.length];
    final suffix =
        _suffixAlphabet[byteAt(2) % _suffixAlphabet.length] +
        _suffixAlphabet[byteAt(3) % _suffixAlphabet.length];
    return 'Vayu-$adjective$animal-$suffix';
  }
}
