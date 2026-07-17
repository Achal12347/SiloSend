enum TransferTransportMode {
  chunkedText,
  nativeFile,
}

class TransferTransportDecision {
  final TransferTransportMode mode;
  final String reason;
  final bool wifiEnabled;
  final bool bluetoothEnabled;
  final int batteryLevel;

  const TransferTransportDecision({
    required this.mode,
    required this.reason,
    required this.wifiEnabled,
    required this.bluetoothEnabled,
    required this.batteryLevel,
  });

  bool get isNativeFile => mode == TransferTransportMode.nativeFile;
}
