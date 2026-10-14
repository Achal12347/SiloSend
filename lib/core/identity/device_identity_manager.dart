import 'dart:async';

import 'package:vayu/core/identity/device_name_generator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';

/// Manages loading, minting, updating, and broadcasting the local Vayu device identity.
class DeviceIdentityManager {
  final IdentityStorage _storage;
  final _identityController = StreamController<LocalDeviceIdentity>.broadcast();

  LocalDeviceIdentity? _currentIdentity;

  DeviceIdentityManager(this._storage);

  /// The currently loaded local device identity, if initialized.
  LocalDeviceIdentity? get currentIdentity => _currentIdentity;

  /// Reactive stream emitting the identity on initialization or updates.
  Stream<LocalDeviceIdentity> get identityStream => _identityController.stream;

  /// Loads an existing persisted identity, or generates and saves a new 16-byte identity on first launch.
  Future<LocalDeviceIdentity> getOrInitializeIdentity({
    required String defaultDisplayName,
    required String platform,
  }) async {
    if (_currentIdentity != null) {
      return _currentIdentity!;
    }

    var stored = await _storage.loadIdentity();
    if (stored != null) {
      // Installs from before generated names all share the legacy name, so
      // two such phones looked identical; give them their own once.
      if (stored.displayName == DeviceNameGenerator.legacyDefaultName) {
        stored = stored.copyWith(
          displayName: DeviceNameGenerator.forDeviceId(stored.deviceId),
        );
        await _storage.saveIdentity(stored);
      }
      _currentIdentity = stored;
      _identityController.add(stored);
      AppLogger.info(
        'DeviceIdentityManager',
        'Loaded existing device identity: ${stored.uuid}',
      );
      return stored;
    }

    // First boot: mint fresh cryptographic 16-byte UUID identity
    var minted = LocalDeviceIdentity.generate(
      displayName: defaultDisplayName,
      platform: platform,
    );
    if (defaultDisplayName == DeviceNameGenerator.legacyDefaultName) {
      minted = minted.copyWith(
        displayName: DeviceNameGenerator.forDeviceId(minted.deviceId),
      );
    }

    await _storage.saveIdentity(minted);
    _currentIdentity = minted;
    _identityController.add(minted);
    AppLogger.info(
      'DeviceIdentityManager',
      'Minted and persisted fresh device identity: ${minted.uuid}',
    );
    return minted;
  }

  /// Loads or mints identity with optional default display name and platform.
  Future<LocalDeviceIdentity> getOrCreateIdentity({
    String defaultDisplayName = DeviceNameGenerator.legacyDefaultName,
    String platform = 'generic',
  }) {
    return getOrInitializeIdentity(
      defaultDisplayName: defaultDisplayName,
      platform: platform,
    );
  }

  /// Updates the user-visible display name and persists the change.
  Future<void> updateDisplayName(String newName) async {
    final current = _currentIdentity;
    if (current == null) {
      throw StateError(
        'Cannot update display name before identity is initialized',
      );
    }

    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        newName,
        'newName',
        'Display name cannot be empty',
      );
    }

    if (trimmed == current.displayName) {
      return; // No change
    }

    final updated = current.copyWith(displayName: trimmed);
    await _storage.saveIdentity(updated);
    _currentIdentity = updated;
    _identityController.add(updated);
    AppLogger.info(
      'DeviceIdentityManager',
      'Updated device display name to: "$trimmed"',
    );
  }

  /// Closes the reactive identity stream controller.
  Future<void> dispose() async {
    await _identityController.close();
  }
}
