import 'dart:typed_data';

/// Encrypts data this phone keeps for itself (chat history) so the file on
/// disk is unreadable without this phone's hardware-held key.
///
/// [aad] names what is sealed; a blob sealed for one purpose does not open
/// for another.
abstract class LocalDataSealer {
  Future<Uint8List> seal(Uint8List data, {required Uint8List aad});

  /// Throws when the blob was not sealed here with [aad] or was changed.
  Future<Uint8List> open(Uint8List blob, {required Uint8List aad});
}
