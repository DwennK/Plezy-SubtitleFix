/// Bounded retry policy. A long quiet section may slow acquisition, but a
/// recognized passage without enough timing evidence should get a prompt retry.
class AnalysisCadence {
  static const confirmationRequests = 10;
  int attempts = 0;
  int _nativeFailures = 0;
  bool _retrySoon = false;
  bool? _previousVoicePresent;
  bool _activityWake = false;
  int? _confirmationRequests;
  bool _tightRetryPending = false;
  bool _tightRetryUsed = false;
  double? _tightRetryThrough;
  bool _awaitingTightRetryResult = false;
  double windowSeconds = 12;

  void clear() {
    attempts = 0;
    _nativeFailures = 0;
    _retrySoon = false;
    _previousVoicePresent = null;
    _activityWake = false;
    _confirmationRequests = null;
    _tightRetryPending = false;
    _tightRetryUsed = false;
    _tightRetryThrough = null;
    _awaitingTightRetryResult = false;
    windowSeconds = 12;
  }

  void submitted() {
    attempts++;
    _activityWake = false;
    if (_tightRetryPending) {
      _tightRetryPending = false;
      _tightRetryUsed = true;
      _awaitingTightRetryResult = true;
      windowSeconds = 15;
    }
    if (_confirmationRequests != null) _confirmationRequests = _confirmationRequests! + 1;
  }

  void evidence({
    required bool recognizedPassage,
    required bool learned,
    bool predictionContradicted = false,
    bool speechTimingRejected = false,
    double? windowEnd,
    double? latestAnchorMediaTime,
  }) {
    final shortResult = _awaitingTightRetryResult;
    _awaitingTightRetryResult = false;
    if (shortResult && windowEnd != null && windowEnd.isFinite) _tightRetryThrough = windowEnd;
    _nativeFailures = 0;
    _retrySoon = recognizedPassage && !learned;
    windowSeconds = learned ? 12 : 15;
    if (learned) {
      _confirmationRequests ??= 0;
      if (!predictionContradicted) _tightRetryUsed = false;
    }
    // New, accepted timing beyond the previous retry's audio may justify a
    // fresh tail. Repeating old anchors or sliding the same window cannot.
    if (!shortResult &&
        speechTimingRejected &&
        _tightRetryUsed &&
        _tightRetryThrough != null &&
        windowEnd != null &&
        windowEnd.isFinite &&
        latestAnchorMediaTime != null &&
        latestAnchorMediaTime.isFinite &&
        latestAnchorMediaTime > _tightRetryThrough! &&
        latestAnchorMediaTime <= windowEnd) {
      _tightRetryUsed = false;
    }
    _tightRetryPending = (predictionContradicted || speechTimingRejected) && !learned && !_tightRetryUsed;
    if (_tightRetryPending) {
      windowSeconds = 8;
      _tightRetryThrough = windowEnd != null && windowEnd.isFinite ? windowEnd : null;
    }
  }

  void rejectedInference() {
    _nativeFailures++;
    _awaitingTightRetryResult = false;
    _tightRetryPending = false;
    // Give transient failures two prompt recovery attempts, then return to
    // sparse acquisition. Never loop continuously on a broken native runtime.
    _retrySoon = _nativeFailures <= 2;
    windowSeconds = 15;
  }

  int intervalMs({required bool synced, required bool established, bool? voicePresent, bool timingMismatch = false}) {
    if (voicePresent != null) {
      if (voicePresent && _previousVoicePresent != true) _activityWake = true;
      if (!voicePresent) _activityWake = false;
      _previousVoicePresent = voicePresent;
    }
    // A contradiction or a speech-rejected cue start can reflect a bad token in a
    // long window. Reanalyze the recent tail once, after the previous result
    // has released its native slot. Repeated failures cannot create a loop.
    if (_tightRetryPending) return 0;
    // Keep one initial analysis and a periodic fallback: the heuristic can
    // miss quiet speech. Activity never changes a mapping or grants a lock.
    if (attempts > 0 && voicePresent == false && !(synced && timingMismatch)) return 90000;
    if (synced) {
      // An initial constant correction still needs a longer baseline to rule
      // out drift. Bound the extra work even if the source stays too sparse.
      // A failed inference must also get its recovery attempts while a previous
      // correction remains active; otherwise it ages for another 30–90 s.
      if (_nativeFailures > 0 && _nativeFailures <= 2) return 12000;
      if (!established &&
          _nativeFailures == 0 &&
          (_confirmationRequests ?? confirmationRequests) < confirmationRequests) {
        return 12000;
      }
      // A mismatch shortens sparse checks, but must never postpone an
      // already faster confirmation or native-failure retry above.
      return established && !timingMismatch ? 90000 : 30000;
    }
    if (_activityWake && _nativeFailures <= 2) return 12000;
    return attempts > 3 && !_retrySoon ? 30000 : 12000;
  }
}
