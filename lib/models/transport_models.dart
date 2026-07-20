enum TransferTransportMode { chunkedText, nativeFile }

extension TransferTransportModeLabel on TransferTransportMode {
  String get label => switch (this) {
    TransferTransportMode.chunkedText => 'Lightweight chunked path',
    TransferTransportMode.nativeFile => 'Native Wi-Fi file path',
  };

  String get summary => switch (this) {
    TransferTransportMode.chunkedText =>
      'Text and smaller files stay on the lightweight path.',
    TransferTransportMode.nativeFile =>
      'Large files switch to the native file transfer path.',
  };
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

  String get label => mode.label;

  String get summary => '$label - $reason';
}
