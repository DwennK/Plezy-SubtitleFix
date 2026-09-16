/// Bounded retry policy. A long quiet section may slow acquisition, but a
/// recognized passage without enough timing evidence should get a prompt retry.
class AnalysisCadence {
  int attempts = 0;
  int _nativeFailures = 0;
  bool _retrySoon = false;
  bool? _previousVoicePresent;
  bool _activityWake = false;
  int? _confirmationRequests;
  double windowSeconds = 12;

  void clear() {
    attempts = 0;
    _nativeFailures = 0;
    _retrySoon = false;
    _previousVoicePresent = null;
    _activityWake = false;
    _confirmationRequests = null;
    windowSeconds = 12;
  }

  void submitted() {
    attempts++;
    _activityWake = false;
    if (_confirmationRequests != null) _confirmationRequests = _confirmationRequests! + 1;
  }

  void evidence({required bool recognizedPassage, required bool learned}) {
    _nativeFailures = 0;
    _retrySoon = recognizedPassage && !learned;
    windowSeconds = learned ? 12 : 15;
    if (learned) _confirmationRequests ??= 0;
  }

  void rejectedInference() {
    _nativeFailures++;
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
    // Keep one initial analysis and a periodic fallback: the heuristic can
    // miss quiet speech. Activity never changes a mapping or grants a lock.
    if (synced && timingMismatch) return 30000;
    if (attempts > 0 && voicePresent == false) return 90000;
    if (synced) {
      // An initial constant correction still needs a longer baseline to rule
      // out drift. Bound the extra work even if the source stays too sparse.
      // A failed inference must also get its recovery attempts while a previous
      // correction remains active; otherwise it ages for another 30–90 s.
      if (_nativeFailures > 0 && _nativeFailures <= 2) return 12000;
      if (!established && _nativeFailures == 0 && (_confirmationRequests ?? 5) < 5) return 12000;
      return established ? 90000 : 30000;
    }
    if (_activityWake && _nativeFailures <= 2) return 12000;
    return attempts > 3 && !_retrySoon ? 30000 : 12000;
  }
}
