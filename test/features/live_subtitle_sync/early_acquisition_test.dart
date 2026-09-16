import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';

void main() {
  const phrases = [
    'carry the silver lantern',
    'walk beside the river',
    'cross the wooden bridge',
    'close the heavy gate',
  ];
  SubtitleAnchor anchor(
    int cue,
    double source, {
    double slope = .96,
    double offset = .5,
    double uncertainty = .35,
    String? phrase,
  }) => SubtitleAnchor(cue, source, source * slope + offset, uncertainty, phrase ?? phrases[cue]);

  test('experiment waits for spaced independent observations before applying a slope', () {
    final tracker = TimelineTracker(experimentalEarlyAcquisition: true);
    expect(tracker.observe([anchor(0, 5), anchor(1, 10)]), isFalse);
    expect(tracker.correctionAt(20).position.automaticDelay, isNull);
    expect(tracker.observe([anchor(2, 25)]), isTrue);
    expect(tracker.map.segments.single.slope, closeTo(.96, 1e-10));
    expect(tracker.correctionAt(35).position.automaticDelay, closeTo(35 - (35 - .5) / .96, 1e-10));
    expect(tracker.correctionAt(35).established, isFalse);
  });

  test('one batch and repeated/refined cues cannot create independent confirmation', () {
    final tracker = TimelineTracker(experimentalEarlyAcquisition: true);
    final batch = [anchor(0, 5), anchor(1, 10), anchor(2, 25)];
    expect(tracker.observe(batch), isFalse);
    expect(tracker.observe(batch), isFalse);
    expect(tracker.observe([anchor(2, 25, offset: .51)]), isFalse);
    expect(tracker.map.segments, isEmpty);
    expect(tracker.observe([anchor(3, 35)]), isTrue);
  });

  test('short spans and duplicate phrases do not qualify', () {
    for (final source in [14.0, 25.0]) {
      final tracker = TimelineTracker(experimentalEarlyAcquisition: true);
      tracker.observe([anchor(0, 5), anchor(1, 10)]);
      expect(tracker.observe([anchor(2, source, phrase: source == 25 ? phrases[0] : null)]), isFalse);
      expect(tracker.map.segments, isEmpty);
    }
  });

  test('invalid observations cannot provide an earlier provenance batch', () {
    for (final invalid in [anchor(0, double.nan), anchor(0, 5, uncertainty: 2), anchor(0, 5, phrase: 'hi')]) {
      final tracker = TimelineTracker(experimentalEarlyAcquisition: true);
      tracker.observe([invalid]);
      expect(tracker.observe([anchor(0, 5), anchor(1, 10), anchor(2, 25)]), isFalse);
      expect(tracker.map.segments, isEmpty);
    }
  });

  test('seeks clear provisional evidence and revoke extrapolation', () {
    final tracker = TimelineTracker(experimentalEarlyAcquisition: true);
    tracker.observe([anchor(0, 5), anchor(1, 10)]);
    tracker.discontinuity();
    expect(tracker.observe([anchor(2, 25)]), isFalse);
    expect(tracker.observe([anchor(0, 5), anchor(1, 10)]), isTrue);
    tracker.discontinuity();
    expect(tracker.correctionAt(35).position.automaticDelay, isNull);
    expect(tracker.correctionAt(15).position.automaticDelay, isNotNull);
  });

  test('a constant edition remains constant and contradictory evidence stays unconfirmed', () {
    final tracker = TimelineTracker(experimentalEarlyAcquisition: true);
    tracker.observe([anchor(0, 5, slope: 1, offset: 90), anchor(1, 10, slope: 1, offset: 90)]);
    expect(tracker.observe([anchor(2, 25, slope: 1, offset: 90)]), isTrue);
    expect(tracker.map.segments.single.slope, 1);
    expect(tracker.correctionAt(120).position.automaticDelay, 90);
    final incompatible = TimelineTracker(experimentalEarlyAcquisition: true);
    incompatible.observe([anchor(0, 5, offset: 90), anchor(1, 10, offset: 90)]);
    expect(incompatible.observe([anchor(2, 25, offset: 10)]), isFalse);
    expect(incompatible.map.segments, isEmpty);
  });

  test('default production acquisition remains unchanged', () {
    final tracker = TimelineTracker();
    expect(tracker.observe([anchor(0, 5), anchor(1, 10)]), isTrue);
    expect(tracker.map.segments.single.slope, 1);
  });
}
