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
