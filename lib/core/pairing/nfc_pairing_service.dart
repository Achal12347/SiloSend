import 'dart:async';
import 'dart:typed_data';

import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/platform/platform_service.dart';

/// Lifecycle status of an NFC pairing operation.
enum NfcOperationStatus {
  idle,
  listening,
  writing,
  success,
  hardwareUnsupported,
  hardwareDisabled,
  invalidPayload,
  timeout,
  error,
}

/// Result of an NFC read or write operation.
class NfcOperationResult {
  final NfcOperationStatus status;
  final String? message;
  final PairingPayload? payload;

  const NfcOperationResult({required this.status, this.message, this.payload});

  bool get isSuccess => status == NfcOperationStatus.success;

  static const unsupported = NfcOperationResult(
    status: NfcOperationStatus.hardwareUnsupported,
    message: 'NFC hardware is unsupported or unavailable on this device',
  );

  static const disabled = NfcOperationResult(
    status: NfcOperationStatus.hardwareDisabled,
    message: 'NFC is turned off in system settings',
  );
}

/// Abstract contract for low-level OS NFC platform operations.
///
/// Implementations can wrap Android NFC Adapter platform channels,
/// third-party plugins, or mock-free test harnesses.
abstract class NfcPlatformAdapter {
  Future<bool> isNfcAvailable();
  Future<bool> isNfcEnabled();
  Future<void> startListening({
    required void Function(Uint8List ndefBytes) onTagDiscovered,
  });
  Future<void> stopListening();

  /// Serves [ndefBytes] to a tapping peer (Android: host card emulation)
  /// until [stopServing].
  Future<void> writeNdef(Uint8List ndefBytes);

  /// Stops serving the last payload so nothing is readable off-screen.
  Future<void> stopServing();
}

/// Why a tap did not deliver anything.
enum NfcTapProblem {
  /// The phones moved apart before the read finished.
  readFailed,

  /// The other phone is not sharing anything (not on Receive or My card).
  notSharing,
}

/// An adapter that reports taps that delivered nothing.
abstract class TapProblemReporting {
  Stream<NfcTapProblem> get tapProblems;
}

/// An adapter that can also share a card as a standard NFC tag, so phones
/// with Vayu closed read it through Android's own tag reader.
abstract class CardSharingNfcAdapter {
  Future<void> serveCard(Uint8List vcard);
}

/// Manages out-of-band NFC pairing exchanges for Vayu.
///
/// Strictly truthful:
/// - Verifies real device capabilities before initiating NFC operations.
/// - Gracefully reports [NfcOperationStatus.hardwareUnsupported] on platforms
///   without NFC hardware (e.g. Windows PC, budget devices, emulators).
/// - Transmits and receives standardized NDEF records carrying [PairingPayload].
///
/// NOTE: NFC pairing provides out-of-band transport connectivity parameters.
/// It does NOT perform cryptographic authentication.
class NfcPairingService {
  final PlatformService platformService;
  final NfcPlatformAdapter? platformAdapter;

  final StreamController<PairingPayload> _payloadController =
      StreamController<PairingPayload>.broadcast();
  final StreamController<NfcOperationStatus> _statusController =
      StreamController<NfcOperationStatus>.broadcast();
  final StreamController<Uint8List> _cardController =
      StreamController<Uint8List>.broadcast();

  NfcOperationStatus _currentStatus = NfcOperationStatus.idle;
  bool _isDisposed = false;

  NfcPairingService({required this.platformService, this.platformAdapter});

  NfcOperationStatus get status => _currentStatus;
  Stream<PairingPayload> get onPayloadReceived => _payloadController.stream;
  Stream<NfcOperationStatus> get onStatusChanged => _statusController.stream;

  /// vCards received by tap (a phone showing its Vayu card). Pairing codes
  /// keep arriving on [onPayloadReceived] as before.
  Stream<Uint8List> get onCardReceived => _cardController.stream;

  /// Taps that delivered nothing, so screens can say what to do.
  Stream<NfcTapProblem> get onTapProblem {
    final adapter = platformAdapter;
    return adapter is TapProblemReporting
        ? (adapter as TapProblemReporting).tapProblems
        : const Stream<NfcTapProblem>.empty();
  }

  /// Whether NFC hardware is present and supported on this device.
  Future<bool> get isNfcAvailable async {
    final adapter = platformAdapter;
    if (adapter != null) {
      return adapter.isNfcAvailable();
    }

    final capabilities = await platformService.getCapabilities();
    return capabilities.supportsNfc;
  }

  /// Whether NFC is currently enabled in OS settings.
  Future<bool> get isNfcEnabled async {
    final adapter = platformAdapter;
    if (adapter != null) {
      return adapter.isNfcEnabled();
    }

    final available = await isNfcAvailable;
    return available;
  }

  /// Starts listening for incoming NFC tags with Vayu NDEF records.
  Future<NfcOperationResult> startReading() async {
    if (_isDisposed) {
      return const NfcOperationResult(
        status: NfcOperationStatus.error,
        message: 'Service is disposed',
      );
    }

    final available = await isNfcAvailable;
    if (!available) {
      _updateStatus(NfcOperationStatus.hardwareUnsupported);
      return NfcOperationResult.unsupported;
    }

    final enabled = await isNfcEnabled;
    if (!enabled) {
      _updateStatus(NfcOperationStatus.hardwareDisabled);
      return NfcOperationResult.disabled;
    }

    final adapter = platformAdapter;
    if (adapter == null) {
      AppLogger.warning(
        'NfcPairingService',
        'NFC reported available but no native platform adapter is attached',
      );
      _updateStatus(NfcOperationStatus.hardwareUnsupported);
      return NfcOperationResult.unsupported;
    }

    try {
      _updateStatus(NfcOperationStatus.listening);
      await adapter.startListening(onTagDiscovered: _handleTagDiscovered);
      return const NfcOperationResult(status: NfcOperationStatus.success);
    } catch (e) {
      AppLogger.error(
        'NfcPairingService',
        'Error starting NFC reader',
        error: e,
      );
      _updateStatus(NfcOperationStatus.error);
      return NfcOperationResult(
        status: NfcOperationStatus.error,
        message: 'Failed to start NFC listening: $e',
      );
    }
  }

  /// Writes a [PairingPayload] as an NDEF record to an adjacent NFC peer or tag.
  Future<NfcOperationResult> writePayload(PairingPayload payload) async {
    if (_isDisposed) {
      return const NfcOperationResult(
        status: NfcOperationStatus.error,
        message: 'Service is disposed',
      );
    }

    final available = await isNfcAvailable;
    if (!available) {
      _updateStatus(NfcOperationStatus.hardwareUnsupported);
      return NfcOperationResult.unsupported;
    }

    final enabled = await isNfcEnabled;
    if (!enabled) {
      _updateStatus(NfcOperationStatus.hardwareDisabled);
      return NfcOperationResult.disabled;
    }

    final adapter = platformAdapter;
    if (adapter == null) {
      _updateStatus(NfcOperationStatus.hardwareUnsupported);
      return NfcOperationResult.unsupported;
    }

    try {
      _updateStatus(NfcOperationStatus.writing);
      final ndefBytes = payload.toNdefBytes();
      await adapter.writeNdef(ndefBytes);
      _updateStatus(NfcOperationStatus.success);
      return NfcOperationResult(
        status: NfcOperationStatus.success,
        payload: payload,
      );
    } catch (e) {
      AppLogger.error(
        'NfcPairingService',
        'Error writing NFC payload',
        error: e,
      );
      _updateStatus(NfcOperationStatus.error);
      return NfcOperationResult(
        status: NfcOperationStatus.error,
        message: 'NFC write failed: $e',
      );
    }
  }

  /// Stops serving this phone's pairing payload.
  Future<void> stopSharing() async {
    try {
      await platformAdapter?.stopServing();
    } catch (_) {}
    _updateStatus(NfcOperationStatus.idle);
  }

  /// Stops active NFC listening.
  Future<void> stopListening() async {
    final adapter = platformAdapter;
    if (adapter != null) {
      try {
        await adapter.stopListening();
      } catch (e) {
        AppLogger.warning(
          'NfcPairingService',
          'Error stopping NFC listening: $e',
        );
      }
    }
    _updateStatus(NfcOperationStatus.idle);
  }

  void _handleTagDiscovered(Uint8List ndefBytes) {
    if (_looksLikeVcard(ndefBytes)) {
      AppLogger.info('NfcPairingService', 'Received a contact card by tap');
      if (!_cardController.isClosed) _cardController.add(ndefBytes);
      return;
    }
    try {
      final payload = PairingPayload.fromNdefBytes(ndefBytes);
      AppLogger.info(
        'NfcPairingService',
        'Received valid pairing payload from ${payload.displayName} (${payload.deviceIdHex})',
      );
      if (!_payloadController.isClosed) {
        _payloadController.add(payload);
      }
    } catch (e) {
      AppLogger.warning(
        'NfcPairingService',
        'Received unparseable or malformed NFC NDEF record: $e',
      );
      _updateStatus(NfcOperationStatus.invalidPayload);
    }
  }

  static final List<int> _vcardPrefix = 'BEGIN:VCARD'.codeUnits;

  static bool _looksLikeVcard(Uint8List bytes) {
    if (bytes.length < _vcardPrefix.length) return false;
    for (var i = 0; i < _vcardPrefix.length; i++) {
      final b = bytes[i];
      final upper = b >= 0x61 && b <= 0x7A ? b - 0x20 : b;
      if (upper != _vcardPrefix[i]) return false;
    }
    return true;
  }

  /// Serves [vcard] over NFC (host card emulation) until [stopSharing], so a
  /// phone tapped against this one receives the card.
  Future<NfcOperationResult> shareCard(Uint8List vcard) async {
    final adapter = platformAdapter;
    if (_isDisposed || adapter == null) return NfcOperationResult.unsupported;
    if (!await isNfcAvailable) return NfcOperationResult.unsupported;
    if (!await isNfcEnabled) return NfcOperationResult.disabled;
    try {
      if (adapter is CardSharingNfcAdapter) {
        await (adapter as CardSharingNfcAdapter).serveCard(vcard);
      } else {
        await adapter.writeNdef(vcard);
      }
      _updateStatus(NfcOperationStatus.writing);
      return const NfcOperationResult(status: NfcOperationStatus.success);
    } catch (e) {
      AppLogger.warning('NfcPairingService', 'Sharing card failed: $e');
      return const NfcOperationResult(status: NfcOperationStatus.error);
    }
  }

  void _updateStatus(NfcOperationStatus newStatus) {
    if (_currentStatus == newStatus) return;
    _currentStatus = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(newStatus);
    }
  }

  /// Disposes the service and closes streams.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    await stopListening();

    if (!_payloadController.isClosed) {
      await _payloadController.close();
    }
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
    if (!_cardController.isClosed) {
      await _cardController.close();
    }
  }
}
