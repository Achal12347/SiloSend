/// Base class for all SiloSend application domain errors.
abstract class AppError implements Exception {
  final String message;
  final Object? cause;

  const AppError(this.message, [this.cause]);

  @override
  String toString() => message;
}

/// Error thrown when required platform permissions are missing or denied.
class PermissionDeniedError extends AppError {
  final String permissionName;

  const PermissionDeniedError(this.permissionName, [Object? cause])
    : super('Permission denied: $permissionName', cause);
}

/// Error thrown when a communication transport is unavailable or fails.
class TransportError extends AppError {
  const TransportError(super.message, [super.cause]);
}

/// Error thrown when security or cryptographic operations fail.
class SecurityError extends AppError {
  const SecurityError(super.message, [super.cause]);
}

/// Error thrown when a requested hardware capability is absent, disabled, or unprobed.
class HardwareUnavailableError extends AppError {
  final String capabilityName;

  const HardwareUnavailableError(this.capabilityName, [Object? cause])
    : super('Hardware unavailable: $capabilityName', cause);
}

/// Error thrown when out-of-band pairing fails or encounters invalid data.
class PairingError extends AppError {
  const PairingError(super.message, [super.cause]);
}
