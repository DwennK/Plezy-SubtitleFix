import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/analysis_cadence.dart';

void main() {
  test('a fresh accepted anchor rearms speech retry only beyond the previously analyzed audio', () {
    final cadence = AnalysisCadence();
    void rejected(double end, double? anchor) => cadence.evidence(
      recognizedPassage: true,
      learned: false,
      speechTimingRejected: true,
      windowEnd: end,
      latestAnchorMediaTime: anchor,
    );
    int delay() => cadence.intervalMs(synced: true, established: true);
    rejected(45, 29);
    expect(delay(), 0);
    cadence.submitted();
    // The short result itself cannot start another immediate retry, even if
    // its tiny new tail contains a later cue. Extend the covered-audio bound.
    rejected(46, 45.5);
    expect(delay(), isNot(0));
    for (final anchor in <double?>[null, 29, 46, 83, double.nan]) {
      rejected(82, anchor);
      expect(delay(), isNot(0));
    }
    rejected(82, 68);
    expect(delay(), 0);
    cadence.submitted();
    for (var i = 0; i < 10; i++) {
      rejected(83 + i.toDouble(), 78);
      expect(delay(), isNot(0));
      cadence.submitted();
    }
    rejected(95, 84);
    expect(delay(), 0);
    cadence.submitted();
    cadence.clear();
    rejected(20, 12);
    expect(delay(), 0);
  });

  test('a speech-rejected timestamp permits only one short retry while an old mapping remains active', () {
    final cadence = AnalysisCadence()..evidence(recognizedPassage: true, learned: true);
    cadence.submitted();
    cadence.evidence(recognizedPassage: true, learned: false, speechTimingRejected: true);
    expect(cadence.windowSeconds, 8);
    expect(cadence.intervalMs(synced: true, established: true, voicePresent: false), 0);
    cadence.submitted();
    for (var i = 0; i < 5; i++) {
      cadence.evidence(recognizedPassage: true, learned: false, speechTimingRejected: true);
      expect(cadence.windowSeconds, 15);
      expect(cadence.intervalMs(synced: true, established: true), isNot(0));
      cadence.submitted();
    }
    cadence.evidence(recognizedPassage: true, learned: true, speechTimingRejected: true);
    expect(cadence.windowSeconds, 12);
    expect(cadence.intervalMs(synced: true, established: true), isNot(0));
    cadence.evidence(recognizedPassage: true, learned: false, speechTimingRejected: true);
    expect(cadence.intervalMs(synced: true, established: true), 0);
  });

  test('continuous music-like activity cannot force fast transcription forever', () {
    final cadence = AnalysisCadence();
    for (var i = 0; i < 5; i++) {
      cadence.submitted();
    }
    expect(cadence.intervalMs(synced: false, established: false, voicePresent: true), 12000);
    cadence.submitted();
    cadence.evidence(recognizedPassage: false, learned: false);
    expect(cadence.intervalMs(synced: false, established: false, voicePresent: true), 30000);
    expect(cadence.intervalMs(synced: false, established: false, voicePresent: false), 90000);
    expect(cadence.intervalMs(synced: false, established: false, voicePresent: true), 12000);
  });

  test('VAD conserves quiet periods, wakes acquisition and only requests rechecks', () {
    final cadence = AnalysisCadence();
    int interval(bool? voice, {bool synced = false, bool mismatch = false}) =>
        cadence.intervalMs(synced: synced, established: true, voicePresent: voice, timingMismatch: mismatch);
    expect(interval(false), 12000);
    cadence.submitted();
    expect(interval(false), 90000);
    expect(interval(true), 12000);
    expect(interval(true, synced: true), 90000);
    expect(interval(true, synced: true, mismatch: true), 30000);
    expect(interval(false, synced: true, mismatch: true), 30000);
    for (var i = 0; i < 5; i++) {
      cadence.submitted();
      cadence.rejectedInference();
    }
    expect(interval(true), 30000);
  });

  int interval(AnalysisCadence cadence) => cadence.intervalMs(synced: false, established: false);

  test('a confirmed timing contradiction allows one immediate short retry, not an inference loop', () {
    final cadence = AnalysisCadence()..evidence(recognizedPassage: true, learned: true);
    cadence.submitted();
    cadence.evidence(recognizedPassage: true, learned: false, predictionContradicted: true);
    expect(cadence.windowSeconds, 8);
    expect(interval(cadence), 0);
    // Timing evidence takes priority over a possibly missed quiet voice.
    expect(cadence.intervalMs(synced: false, established: false, voicePresent: false), 0);
    cadence.submitted();
    expect(cadence.windowSeconds, 15);
    for (var i = 0; i < 5; i++) {
      cadence.evidence(recognizedPassage: true, learned: false, predictionContradicted: true);
      expect(interval(cadence), 12000);
      expect(cadence.windowSeconds, 15);
      cadence.submitted();
    }
    cadence.rejectedInference();
    cadence.evidence(recognizedPassage: true, learned: false, predictionContradicted: true);
    expect(interval(cadence), 12000);
  });

  test('short retries rearm only after confirmed recovery or a new playback generation', () {
    final cadence = AnalysisCadence();
    for (final reset in ['learned', 'clear']) {
      cadence.evidence(recognizedPassage: true, learned: false, predictionContradicted: true);
      expect(interval(cadence), 0);
      cadence.submitted();
      cadence.evidence(recognizedPassage: false, learned: false);
      expect(interval(cadence), isNot(0));
      cadence.evidence(recognizedPassage: true, learned: false, predictionContradicted: true);
      expect(interval(cadence), isNot(0));
      reset == 'clear' ? cadence.clear() : cadence.evidence(recognizedPassage: true, learned: true);
    }
    cadence.evidence(recognizedPassage: true, learned: false, predictionContradicted: true);
    expect(interval(cadence), 0);
    cadence.clear();
    expect(cadence.windowSeconds, 12);
    expect(interval(cadence), 12000);
  });

  test('unconfirmed dialogue, VAD and a known mapping cannot request an immediate short retry', () {
    final cadence = AnalysisCadence();
    cadence.evidence(recognizedPassage: true, learned: false);
    expect(cadence.windowSeconds, 15);
    expect(interval(cadence), 12000);
    cadence.evidence(recognizedPassage: true, learned: true);
    expect(cadence.windowSeconds, 12);
    expect(cadence.intervalMs(synced: true, established: true, voicePresent: true), 90000);
  });

  test('quiet intro backs off but weak recognized dialogue promptly retries a wider window', () {
    final cadence = AnalysisCadence();
    for (var i = 0; i < 6; i++) {
      cadence.submitted();
      cadence.evidence(recognizedPassage: false, learned: false);
    }
    expect(interval(cadence), 30000);
    cadence.evidence(recognizedPassage: true, learned: false);
    expect(interval(cadence), 12000);
    expect(cadence.windowSeconds, 15);
    cadence.evidence(recognizedPassage: true, learned: true);
    expect(cadence.windowSeconds, 12);
    expect(cadence.intervalMs(synced: true, established: false), 12000);
    expect(cadence.intervalMs(synced: true, established: true), 90000);
  });

  test('initial correction has a bounded confirmation phase and still retries native failures', () {
    final cadence = AnalysisCadence()..evidence(recognizedPassage: true, learned: true);
    // Early acquisition at ~21 s must keep sampling past 81 s: sparse cue
    // starts may not establish a slope during the first five confirmations.
    for (var i = 0; i < 10; i++) {
      expect(cadence.intervalMs(synced: true, established: false), 12000);
      cadence.submitted();
      cadence.evidence(recognizedPassage: true, learned: true);
    }
    expect(cadence.intervalMs(synced: true, established: false), 30000);
    expect(cadence.intervalMs(synced: true, established: true), 90000);
    for (var i = 0; i < 2; i++) {
      cadence.rejectedInference();
      expect(cadence.intervalMs(synced: true, established: true), 12000);
      cadence.submitted();
    }
    cadence.rejectedInference();
    expect(cadence.intervalMs(synced: true, established: false), 30000);
    expect(cadence.intervalMs(synced: true, established: true), 90000);
    cadence.clear();
    cadence.evidence(recognizedPassage: true, learned: true);
    expect(cadence.intervalMs(synced: true, established: false), 12000);
  });

  test('transient inference failure retries twice without creating an unbounded fast loop', () {
    final cadence = AnalysisCadence();
    for (var i = 0; i < 6; i++) {
      cadence.submitted();
    }
    for (var i = 0; i < 2; i++) {
      cadence.rejectedInference();
      expect(interval(cadence), 12000);
      cadence.submitted();
    }
    cadence.rejectedInference();
    expect(interval(cadence), 30000);
    cadence.evidence(recognizedPassage: false, learned: false);
    cadence.rejectedInference();
    expect(interval(cadence), 12000);
    cadence.clear();
    expect(cadence.attempts, 0);
    expect(cadence.windowSeconds, 12);
    expect(interval(cadence), 12000);
  });
}
