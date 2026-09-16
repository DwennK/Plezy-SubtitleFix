import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';

SubtitleAnchor anchor(int cue, double subtitle, double media, {String? phrase, double uncertainty = 0.35}) =>
    SubtitleAnchor(cue, subtitle, media, uncertainty, phrase ?? 'independent dialogue phrase $cue');

TimelineTracker learned() => TimelineTracker()..observe([anchor(0, 100, 104), anchor(1, 110, 114)]);

void main() {
  test('two contradictory cue starts revoke prediction before a replacement fit is possible', () {
    final tracker = learned();
    final known = tracker.map;
    expect(tracker.observe([anchor(2, 130, 164), anchor(3, 140, 172)]), isFalse);
    expect(identical(tracker.map, known), isTrue);
    expect(tracker.correctionAt(108).position.automaticDelay, 4);
    expect(tracker.correctionAt(180).position.kind, TimelineRegionKind.unknown);
    expect(tracker.map.gaps, isEmpty);
    // Replayed/refined pre-edit dialogue must not resurrect its prediction.
    tracker.observe([anchor(1, 110, 114.1)]);
    expect(tracker.correctionAt(180).position.kind, TimelineRegionKind.unknown);
    // A genuinely confirmed new region supplies its own prediction.
    expect(tracker.observe([anchor(3, 140, 174)]), isTrue);
    expect(tracker.correctionAt(180).position.automaticDelay, closeTo(34, 1e-9));
  });

  test('real crossing-cue timestamps stop claiming the old offset while new timing is uncertain', () {
    final tracker = TimelineTracker()..observe([anchor(3, 121.75, 21.4470416667), anchor(6, 129.4, 29.3270416667)]);
    final old = tracker.correctionAt(50).position.automaticDelay;
    expect(old, closeTo(-100.1879583333, 1e-8));
    // Numeric anchors from current-native 6ff7ae18 development evidence.
    expect(tracker.observe([anchor(8, 138, 67.7656666667), anchor(10, 148.85, 76.5656666667)]), isFalse);
    expect(tracker.correctionAt(82).position.kind, TimelineRegionKind.unknown);
    expect(tracker.correctionAt(27).position.automaticDelay, old);
    expect(tracker.map.gaps, isEmpty);
  });

  test('a removal can invalidate extrapolation without pretending to locate the cut', () {
    final tracker = learned();
    expect(tracker.observe([anchor(2, 145, 129), anchor(3, 155, 141)]), isFalse);
    expect(tracker.correctionAt(150).position.kind, TimelineRegionKind.unknown);
    expect(tracker.map.gaps, isEmpty);
    tracker.discontinuity();
    expect(tracker.correctionAt(108).position.automaticDelay, 4);
    expect(tracker.observe([anchor(0, 100, 104), anchor(1, 110, 114)]), isTrue);
    expect(tracker.correctionAt(120).position.automaticDelay, 4);
  });

  test('recovery may correct an overestimated media timestamp on the same final cue', () {
    final tracker = learned();
    expect(tracker.observe([anchor(2, 130, 164), anchor(3, 140, 176)]), isFalse);
    expect(tracker.correctionAt(180).position.kind, TimelineRegionKind.unknown);
    expect(tracker.observe([anchor(3, 140, 174)]), isTrue);
    expect(tracker.correctionAt(180).position.automaticDelay, 34);
  });

  test('old context in the contradictory batch cannot dilute subsequent recovery', () {
    final tracker = learned();
    expect(tracker.observe([anchor(1, 110, 114.1), anchor(2, 130, 164), anchor(3, 140, 172)]), isFalse);
    expect(tracker.correctionAt(180).position.kind, TimelineRegionKind.unknown);
    expect(tracker.observe([anchor(3, 140, 174)]), isTrue);
    expect(tracker.correctionAt(180).position.automaticDelay, 34);
  });

  test('an unconfirmed pre-edit cue cannot block a corrected post-edit cluster', () {
    final tracker = TimelineTracker()..observe([anchor(3, 121.75, 21.452375), anchor(6, 129.4, 29.332375)]);
    // A timestamp near the old mapping, outside its observed source domain.
    // It cannot be removed as an already-fitted interior outlier.
    expect(tracker.observe([anchor(7, 135, 33.2896875)]), isFalse);
    expect(tracker.observe([anchor(8, 138, 67.760375), anchor(10, 148.85, 76.000375)]), isFalse);
    expect(tracker.correctionAt(82).predictionContradicted, isTrue);
    // Context may replay this older, never-confirmed cue while recovering.
    expect(tracker.observe([anchor(7, 135, 33.3)]), isFalse);
    // Numeric timestamp recovered by the real 8-second retry at 1a5695d4.
    expect(tracker.observe([anchor(10, 148.85, 78.975)]), isTrue);
    expect(tracker.correctionAt(83).position.automaticDelay, closeTo(-70.0573125, 1e-8));
    expect(tracker.correctionAt(83).predictionContradicted, isFalse);
    expect(tracker.correctionAt(27).position.automaticDelay, closeTo(-100.182625, 1e-8));
    expect(tracker.map.gaps, isEmpty);
  });

  test('one cue, repeated words, opposite errors and invalid timestamps do not revoke', () {
    final examples = <List<SubtitleAnchor>>[
      [anchor(2, 130, 164)],
      [anchor(2, 130, 164), anchor(2, 140, 172)],
      [anchor(2, 130, 164, phrase: 'Same short phrase'), anchor(3, 140, 172, phrase: 'same short phrase!')],
      [anchor(2, 130, 164), anchor(3, 150, 134)],
      [anchor(2, 130, 164), anchor(3, 140, 172, uncertainty: double.nan)],
      [anchor(2, 130, 164), anchor(3, 140, double.infinity)],
      [anchor(2, 130, 164), anchor(3, 140, 172, phrase: 'yes')],
      [anchor(2, 130, 164), anchor(3, 132, 167)],
      // Evidence beyond the bounded continuous-prediction horizon is unrelated.
      [anchor(2, 300, 364), anchor(3, 310, 372)],
    ];
    for (final observations in examples) {
      final tracker = learned();
      tracker.observe(observations);
      expect(tracker.correctionAt(120).position.automaticDelay, 4);
    }
  });

  test('all supported cadence slopes and timestamp tolerance retain their predictions', () {
    for (final slope in [0.9, 23.976 / 25, 1.0, 25 / 23.976, 1.1]) {
      final tracker = learned();
      tracker.observe([anchor(2, 130, 114 + slope * 20 - 0.8), anchor(3, 150, 114 + slope * 40 + 0.8)]);
      expect(tracker.correctionAt(190).position.kind, TimelineRegionKind.aligned);
    }
  });

  test('seek and clear cannot combine pre-seek contradictions with new evidence', () {
    for (final clear in [false, true]) {
      final tracker = learned();
      tracker.observe([anchor(2, 130, 164)]);
      clear ? tracker.clear() : tracker.discontinuity();
      tracker.observe([anchor(3, 140, 172)]);
      expect(tracker.correctionAt(180).position.kind, TimelineRegionKind.unknown);
      expect(tracker.map.gaps, isEmpty);
      expect(tracker.map.segments.length, clear ? 0 : 1);
    }
  });

  test('contradiction presentation is local to the audio-adjusted domain and resets on recovery', () {
    final tracker = learned();
    expect(tracker.correctionAt(180).predictionContradicted, isFalse);
    tracker.observe([anchor(2, 130, 164), anchor(3, 140, 172)]);
    expect(tracker.correctionAt(180).predictionContradicted, isTrue);
    expect(tracker.correctionAt(180).suppressSubtitles, isTrue);
    expect(tracker.correctionAt(300).suppressSubtitles, isFalse);
    expect(tracker.correctionAt(108).predictionContradicted, isFalse);
    expect(tracker.correctionAt(150).predictionContradicted, isFalse);
    expect(tracker.correctionAt(166, audioDelay: 3).predictionContradicted, isFalse);
    expect(tracker.correctionAt(168, audioDelay: 3).predictionContradicted, isTrue);
    expect(tracker.correctionAt(163, audioDelay: -2).predictionContradicted, isTrue);
    expect(tracker.correctionAt(double.infinity).predictionContradicted, isFalse);
    expect(tracker.correctionAt(180, audioDelay: double.nan).predictionContradicted, isFalse);
    tracker.observe([anchor(3, 140, 174)]);
    expect(tracker.correctionAt(180).predictionContradicted, isFalse);
    expect(tracker.correctionAt(180).position.automaticDelay, 34);
    expect(tracker.map.gaps, isEmpty);
  });

  test('seek, stop and cache restore discard transient contradiction presentation', () {
    for (final reset in ['seek', 'clear', 'restore']) {
      final tracker = learned();
      final known = tracker.map;
      tracker.observe([anchor(2, 130, 164), anchor(3, 140, 172)]);
      expect(tracker.correctionAt(180).predictionContradicted, isTrue);
      switch (reset) {
        case 'seek':
          tracker.discontinuity();
        case 'clear':
          tracker.clear();
        case 'restore':
          tracker.restore(known);
      }
      expect(tracker.correctionAt(180).predictionContradicted, isFalse);
      expect(tracker.map.gaps, isEmpty);
    }
  });
}
