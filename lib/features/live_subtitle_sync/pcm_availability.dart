/// Detects a missing capture, not silence (silent audio still contains PCM).
/// Count only observed active playback; pause/buffering and large polling gaps
/// must not turn startup latency into an immediate failure after resuming.
class PcmAvailability {
  int? _previousMs;
  int _emptyMs = 0;

  void clear() {
    _previousMs = null;
    _emptyMs = 0;
  }

  bool expired({required int nowMs, required int samples, required bool playing, required bool buffering}) {
    final previous = _previousMs;
    _previousMs = nowMs;
    if (previous == null || nowMs < previous || !playing || buffering || samples > 0) {
      _emptyMs = 0;
      return false;
    }
    _emptyMs += (nowMs - previous).clamp(0, 1000);
    return _emptyMs >= 30000;
  }
}
