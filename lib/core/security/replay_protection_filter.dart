/// Replay check decision outcomes.
enum ReplayDecision {
  /// Packet has a sequence number greater than rxWindowMax.
  acceptNewer,

  /// Packet is within the 64-packet sliding window and has not been seen before.
  acceptWindow,

  /// Packet sequence number has already been seen within the sliding window.
  rejectDuplicate,

  /// Packet sequence number is older than (rxWindowMax - 63) and has fallen off the window.
  rejectStale,
}

/// Implements the standard RFC 6479 / IPsec 64-packet anti-replay sliding-window algorithm.
///
/// CRITICAL SECURITY RULE:
/// The replay filter state must only be committed via [commitSequence] AFTER
/// the packet's AEAD authentication tag has been successfully verified.
/// Unauthenticated packets must never mutate window state.
class ReplayProtectionFilter {
  static const int windowSize = 64;
  static const int _mask64 = 0xFFFFFFFFFFFFFFFF;

  int _rxWindowMax = 0;
  int _rxBitmap = 0;
  bool _isInitialized = false;

  int get rxWindowMax => _rxWindowMax;
  int get rxBitmap => _rxBitmap;
  bool get isInitialized => _isInitialized;

  /// Checks whether [sequenceNumber] is acceptable without mutating filter state.
  ReplayDecision checkSequence(int sequenceNumber) {
    if (sequenceNumber < 0) {
      return ReplayDecision.rejectStale;
    }

    if (!_isInitialized) {
      return ReplayDecision.acceptNewer;
    }

    if (sequenceNumber > _rxWindowMax) {
      return ReplayDecision.acceptNewer;
    }

    final delta = _rxWindowMax - sequenceNumber;
    if (delta >= windowSize) {
      return ReplayDecision.rejectStale;
    }

    final mask = 1 << delta;
    if ((_rxBitmap & mask) != 0) {
      return ReplayDecision.rejectDuplicate;
    }

    return ReplayDecision.acceptWindow;
  }

  /// Commits [sequenceNumber] into the sliding window state.
  ///
  /// MUST be invoked only after the caller has verified the AEAD authentication tag.
  void commitSequence(int sequenceNumber) {
    if (!_isInitialized) {
      _isInitialized = true;
      _rxWindowMax = sequenceNumber;
      _rxBitmap = 1;
      return;
    }

    if (sequenceNumber > _rxWindowMax) {
      final advance = sequenceNumber - _rxWindowMax;
      if (advance < windowSize) {
        _rxBitmap = ((_rxBitmap << advance) | 1) & _mask64;
      } else {
        _rxBitmap = 1;
      }
      _rxWindowMax = sequenceNumber;
    } else {
      final delta = _rxWindowMax - sequenceNumber;
      if (delta < windowSize) {
        _rxBitmap = (_rxBitmap | (1 << delta)) & _mask64;
      }
    }
  }

  /// Resets the sliding window state (e.g. for a new key epoch or fresh session).
  void reset() {
    _rxWindowMax = 0;
    _rxBitmap = 0;
    _isInitialized = false;
  }
}
