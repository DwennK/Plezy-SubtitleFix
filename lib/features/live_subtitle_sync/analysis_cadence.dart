/// Bounded retry policy. A long quiet section may slow acquisition, but a
/// recognized passage without enough timing evidence should get a prompt retry.
class AnalysisCadence {
  int attempts = 0;
  int _nativeFailures = 0;
  bool _retrySoon = false;
  double windowSeconds = 12;

  void clear() {
    attempts = 0;
    _nativeFailures = 0;
    _retrySoon = false;
    windowSeconds = 12;
  }

  void submitted() => attempts++;

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

  int intervalMs({required bool synced, required bool established}) {
    if (synced) return established ? 90000 : 30000;
    return attempts > 3 && !_retrySoon ? 30000 : 12000;
  }
}
