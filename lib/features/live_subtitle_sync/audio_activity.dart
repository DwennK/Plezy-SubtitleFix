import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

class AudioActivity {
  const AudioActivity(this.generation, this.continuity, this.start, this.end, this.voiceSeconds);
  final int generation;
  final int continuity;
  final double start;
  final double end;
  final double voiceSeconds;
  double get observedSeconds => end - start;
}

class _ActivityFrame {
  const _ActivityFrame(this.start, this.end, this.voice);
  final double start;
  final double end;
  final bool voice;
}

/// Streaming heuristic VAD on mono float32 16 kHz. Energy, a speech-band
/// filter and zero crossings provide a scheduling hint, never a text match or
/// probability. Music can activate it; quiet speech can be missed. Periodic
/// ASR remains available. PCM is neither copied into this object nor retained.
class VoiceActivityDetector {
  static const _frameSamples = 320;
  final _frames = ListQueue<_ActivityFrame>();
  int? _generation;
  int? _continuity;
  double? _nextTime;
  double _step = 0;
  double _frameStart = 0;
  int _count = 0;
  int _crossings = 0;
  int _hangover = 0;
  double _energy = 0;
  double _bandEnergy = 0;
  double _lastInput = 0;
  double _high = 0;
  double _low = 0;
  double _previousBand = 0;
  double _noisePower = 0.000001;

  void clear() {
    _frames.clear();
    _generation = _continuity = null;
    _nextTime = null;
    _step = _frameStart = 0;
    _count = _crossings = _hangover = 0;
    _energy = _bandEnergy = _lastInput = _high = _low = _previousBand = 0;
    _noisePower = 0.000001;
  }

  AudioActivity? observe(
    Float32List samples, {
    required int generation,
    required int continuity,
    required double start,
    required double secondsPerSample,
  }) {
    if (samples.isEmpty ||
        samples.length > 32000 ||
        !start.isFinite ||
        !secondsPerSample.isFinite ||
        secondsPerSample <= 0 ||
        secondsPerSample > 16 / 16000) {
      return null;
    }
    if (_generation != generation ||
        _continuity != continuity ||
        _step != secondsPerSample ||
        _nextTime != null && start > _nextTime! + secondsPerSample * 2) {
      clear();
    }
    _generation = generation;
    _continuity = continuity;
    _step = secondsPerSample;
    // Repeated/overlapping snapshots must not count the same voice twice or
    // adapt the noise floor again. Native sample times have one-sample precision.
    final skip = _nextTime == null ? 0 : ((_nextTime! - start) / _step).round().clamp(0, samples.length);
    for (var i = skip; i < samples.length; i++) {
      final value = samples[i];
      if (!value.isFinite || value.abs() > 1) {
        clear();
        return null;
      }
      final time = start + i * _step;
      if (_count == 0) _frameStart = time;
      // One-pole 80 Hz high-pass followed by a 3.8 kHz low-pass.
      _high = 0.969072426 * (_high + value - _lastInput);
      _lastInput = value;
      _low += 0.77510053 * (_high - _low);
      if ((_low >= 0) != (_previousBand >= 0)) _crossings++;
      _previousBand = _low;
      _energy += value * value;
      _bandEnergy += _low * _low;
      _count++;
      _nextTime = time + _step;
      if (_count != _frameSamples) continue;
      final power = _energy / _frameSamples;
      final crossings = _crossings / _frameSamples;
      final possibleVoice =
          power > math.max(0.000016, _noisePower * 3) &&
          _bandEnergy > _energy * 0.25 &&
          crossings >= 0.015 &&
          crossings <= 0.30;
      if (possibleVoice) {
        _hangover = 10;
      } else {
        _hangover = math.max(0, _hangover - 1);
        // Follow low background levels slowly; a loud non-speech event must
        // not raise the floor enough to mask subsequent quiet dialogue.
        _noisePower = 0.98 * _noisePower + 0.02 * math.min(power, 0.000016);
      }
      _frames.add(_ActivityFrame(_frameStart, _nextTime!, possibleVoice || _hangover > 0));
      while (_frames.length > 1500 || _frames.first.end <= _nextTime! - 12) {
        _frames.removeFirst();
      }
      _count = _crossings = 0;
      _energy = _bandEnergy = 0;
    }
    if (_frames.isEmpty) return null;
    final end = _frames.last.end;
    final beginning = math.max(_frames.first.start, end - 12);
    final voiced = _frames
        .where((frame) => frame.voice)
        .fold<double>(0, (sum, frame) => sum + frame.end - math.max(frame.start, beginning));
    return AudioActivity(generation, continuity, beginning, end, voiced);
  }
}
