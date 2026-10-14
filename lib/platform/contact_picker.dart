import 'package:flutter/services.dart';

/// A contact the user picked, as the contacts app exported it.
class PickedContact {
  final String name;
  final Uint8List vcard;

  const PickedContact({required this.name, required this.vcard});
}

class ContactPickerException implements Exception {
  final String code;
  const ContactPickerException(this.code);
  bool get isPermissionDenied => code == 'PERMISSION';
}

/// Bridge to ContactsHandler: system contact picker and private card storage.
class ContactPicker {
  static const MethodChannel _channel = MethodChannel(
    'com.achyrio.vayu/contacts',
  );

  const ContactPicker();

  /// Returns the picked contact, or null when the user backed out.
  Future<PickedContact?> pick() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('pick');
      if (result == null) return null;
      return PickedContact(
        name: result['name'] as String? ?? 'Contact',
        vcard: result['vcard'] as Uint8List,
      );
    } on PlatformException catch (e) {
      throw ContactPickerException(e.code);
    } on MissingPluginException {
      throw const ContactPickerException('UNSUPPORTED');
    }
  }

  /// App-private folder for received contact cards.
  Future<String?> privateDirectory() async {
    try {
      return await _channel.invokeMethod<String>('privateDirectory');
    } catch (_) {
      return null;
    }
  }
}
