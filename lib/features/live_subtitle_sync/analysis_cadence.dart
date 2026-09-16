/// Bounded retry policy. A long quiet section may slow acquisition, but a
/// recognized passage without enough timing evidence should get a prompt retry.
class AnalysisCadence {
  int attempts = 0;
  int _nativeFailures = 0;
  bool _retrySoon = false;
  bool? _previousVoicePresent;
  bool _activityWake = false;
  double windowSeconds = 12;

  void clear() {
    attempts = 0;
    _nativeFailures = 0;
    _retrySoon = false;
    _previousVoicePresent = null;
    _activityWake = false;
    windowSeconds = 12;
  }

  void submitted() {
    attempts++;
    _activityWake = false;
  }

  void evidence({required bool recognizedPassage, required bool learned}) {
    _nativeFailures = 0;
    _retrySoon = recognizedPassage && !learned;
    windowSeconds = learned ? 12 : 15;
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
    if (synced) return established ? 90000 : 30000;
    if (_activityWake && _nativeFailures <= 2) return 12000;
    return attempts > 3 && !_retrySoon ? 30000 : 12000;
  }
}
