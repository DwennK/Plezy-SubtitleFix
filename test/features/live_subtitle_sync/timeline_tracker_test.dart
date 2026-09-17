import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/analysis_cadence.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';

SubtitleAnchor anchor(int cue, double subtitle, double media) =>
    SubtitleAnchor(cue, subtitle, media, 0.35, 'distinct phrase number $cue');

void main() {
  test('a later unknown passage accumulates independent anchors across short windows', () {
    final tracker = TimelineTracker();
    tracker.observe([anchor(0, 100, 104.245), anchor(1, 102.219, 105.405)]);
    expect(tracker.observe([anchor(2, 113.361, 116.579), anchor(3, 116.016, 118.659)]), isTrue);
    expect(tracker.observe([anchor(4, 125.678, 128.951), anchor(5, 128.898, 133.411)]), isTrue);
    final earlier = tracker.map.segments.toList();
    expect(earlier, hasLength(2));
    final shortPassage = [anchor(6, 148.657, 152.623), anchor(7, 150.572, 153.903)];
    expect(tracker.observe(shortPassage), isFalse);
    // The invalid historical fit is not new evidence against extrapolation.
    expect(tracker.correctionAt(155).position.automaticDelay, closeTo(3.893, 1e-9));
    expect(tracker.observe(shortPassage), isFalse);
    expect(tracker.observe([anchor(8, 163.933, 166.919)]), isTrue);
    expect(tracker.correctionAt(170).position.automaticDelay, closeTo(3.331, 1e-9));
    expect(tracker.map.segments.take(2), orderedEquals(earlier));
    expect(tracker.map.segments.last.anchors.map((a) => a.cue), [6, 7, 8]);
    expect(tracker.map.atMedia(140).kind, TimelineRegionKind.unknown);
    expect(tracker.map.gaps, isEmpty);
  });

  test('unknown-passage accumulation retains independence, consistency and continuity gates', () {
    for (final later in [
      [anchor(6, 150, 154), anchor(7, 151, 159), anchor(8, 165, 177)],
      [anchor(6, 150, 154), anchor(7, 151, 155), anchor(8, 152, 156)],
      [anchor(6, 150, 154), anchor(7, 151, 155), anchor(8, 300, 304)],
      [
        const SubtitleAnchor(6, 150, 154, 0.35, 'one repeated phrase'),
        const SubtitleAnchor(7, 151, 155, 0.35, 'one repeated phrase'),
        const SubtitleAnchor(8, 165, 169, 0.35, 'one repeated phrase'),
      ],
    ]) {
      final tracker = TimelineTracker();
      tracker.observe([anchor(0, 100, 104.245), anchor(1, 102.219, 105.405)]);
      tracker.observe([anchor(2, 113.361, 116.579), anchor(3, 116.016, 118.659)]);
      tracker.observe([anchor(4, 125.678, 128.951), anchor(5, 128.898, 133.411)]);
      final earlier = tracker.map.segments.toList();
      expect(tracker.observe(later.take(2).toList()), isFalse);
      expect(tracker.observe([later.last]), isFalse);
      expect(tracker.map.segments, orderedEquals(earlier));
      expect(tracker.map.gaps, isEmpty);
    }
  });

  test('an old outlier cannot bridge contradictory history and block a fresh later region', () {
    final tracker = TimelineTracker();
    expect(tracker.observe([anchor(0, 100, 104.25), anchor(1, 102, 105.19)]), isFalse);
    expect(tracker.observe([anchor(2, 114, 117.22), anchor(3, 117, 119.65)]), isTrue);
    expect(tracker.observe([anchor(4, 130, 133.27), anchor(5, 134, 138.51)]), isTrue);
    final earlier = tracker.map.segments.toList();
    expect(earlier, hasLength(2));
    expect(tracker.observe([anchor(6, 154, 157.96), anchor(7, 159, 162.38)]), isTrue);
    expect(tracker.correctionAt(165).position.automaticDelay, closeTo(3.67, 1e-9));
    expect(tracker.map.segments, hasLength(3));
    expect(tracker.map.segments.take(2), orderedEquals(earlier));
    expect(tracker.map.atMedia(150).kind, TimelineRegionKind.unknown);
    expect(tracker.map.gaps, isEmpty);
  });

  test('inconsistent earlier observations cannot block an independently confirmed later region', () {
    final tracker = TimelineTracker();
    expect(tracker.observe([anchor(0, 100, 100), anchor(1, 110, 114), anchor(2, 120, 128)]), isFalse);
    expect(tracker.observe([anchor(3, 200, 202), anchor(4, 210, 212)]), isTrue);
    expect(tracker.correctionAt(215).position.automaticDelay, 2);
    expect(tracker.map.segments.single.subtitleStart, 200);
    expect(tracker.map.atMedia(150).kind, TimelineRegionKind.unknown);
    expect(tracker.map.gaps, isEmpty);
  });

  test('fresh evidence still needs independent, spaced and consistent cue starts', () {
    for (final recent in [
      [anchor(3, 200, 202)],
      [anchor(3, 200, 202), anchor(4, 202, 204)],
      [anchor(3, 200, 202), anchor(4, 210, 216), anchor(5, 220, 230)],
    ]) {
      final tracker = TimelineTracker();
      tracker.observe([anchor(0, 100, 100), anchor(1, 110, 114), anchor(2, 120, 128)]);
      expect(tracker.observe(recent), isFalse);
      expect(tracker.map.segments, isEmpty);
      expect(tracker.correctionAt(240).position.kind, TimelineRegionKind.unknown);
    }
  });

  test('replayed context does not rewrite a mapping or count as fresh timing evidence', () {
    final tracker = TimelineTracker();
    final observations = [anchor(0, 100, 104), anchor(1, 110, 114)];
    expect(tracker.observe(observations), isTrue);
    final learned = tracker.map;
    final cadence = AnalysisCadence()..evidence(recognizedPassage: true, learned: true);
    expect(cadence.windowSeconds, 12);
    final repeated = tracker.observe([anchor(0, 100, 104), anchor(1, 110, 114)]);
    expect(repeated, isFalse);
    cadence.evidence(recognizedPassage: true, learned: repeated);
    expect(cadence.windowSeconds, 15);
    expect(identical(tracker.map, learned), isTrue);
    expect(tracker.observe([]), isFalse);
    expect(identical(tracker.map, learned), isTrue);
  });

  test('a genuinely refined timestamp still updates the correction', () {
    final tracker = TimelineTracker()..observe([anchor(0, 100, 104), anchor(1, 110, 114)]);
    expect(tracker.observe([anchor(1, 110, 114.2)]), isTrue);
    expect(tracker.correctionAt(120).position.automaticDelay, closeTo(4.1, 1e-9));
    expect(tracker.map.segments.single.anchors.singleWhere((a) => a.cue == 1).mediaTime, 114.2);
    expect(tracker.observe([anchor(1, 110, 114.2)]), isFalse);
  });

  test('a seek allows independently reobserved cue starts to validate a restored region', () {
    final observations = [for (var i = 0; i < 6; i++) anchor(i, 100 + i * 20, 104 + i * 20)];
    final tracker = TimelineTracker()..observe(observations);
    tracker.restore(tracker.map);
    expect(tracker.correctionAt(150).established, isFalse);
    expect(tracker.observe([observations[0]]), isFalse);
    expect(tracker.observe([observations[0]]), isFalse);
    expect(tracker.observe([observations[1]]), isTrue);
    expect(tracker.correctionAt(150).established, isTrue);
  });

  test('an established old scene cannot slow confirmation in a newly learned scene', () {
    final tracker = TimelineTracker()
      ..observe([for (var i = 0; i < 6; i++) anchor(i, 100 + i * 20, 104 + i * 20)])
      ..discontinuity();
    expect(tracker.observe([anchor(6, 500, 504), anchor(7, 510, 514)]), isTrue);
    final cadence = AnalysisCadence()..evidence(recognizedPassage: true, learned: true);
    int interval(double time) => cadence.intervalMs(synced: true, established: tracker.correctionAt(time).established);
    expect(interval(508), 12000);
    expect(interval(530), 12000);
    expect(interval(180), 90000);
    expect(tracker.correctionAt(350).established, isFalse);
  });

  test('fresh validation belongs to its cached scene, without being blocked by other cached scenes', () {
    const fitter = TimelineFitter();
    final tracker = TimelineTracker()
      ..restore(
        TimelineMap(
          segments: [
            fitter.fit([for (var i = 0; i < 6; i++) anchor(i, 100 + i * 20, 104 + i * 20)])!,
            fitter.fit([for (var i = 0; i < 6; i++) anchor(i + 6, 500 + i * 20, 504 + i * 20)])!,
          ],
        ),
      );
    expect(tracker.correctionAt(150).established, isFalse);
    expect(tracker.correctionAt(550).established, isFalse);
    expect(tracker.observe([anchor(0, 100, 104), anchor(1, 120, 124)]), isTrue);
    expect(tracker.correctionAt(150).established, isTrue);
    expect(tracker.correctionAt(230).established, isTrue);
    expect(tracker.correctionAt(550).established, isFalse);
  });

  test('established status follows audio delay and expires with its prediction', () {
    final tracker = TimelineTracker()..observe([for (var i = 0; i < 6; i++) anchor(i, 100 + i * 20, 104 + i * 20)]);
    expect(tracker.correctionAt(230).established, isTrue);
    expect(tracker.correctionAt(350).established, isFalse);
    tracker.discontinuity();
    expect(tracker.correctionAt(230).established, isFalse);
    expect(tracker.correctionAt(190).established, isTrue);
    expect(tracker.correctionAt(270).established, isFalse);
    expect(tracker.correctionAt(270, audioDelay: 80).established, isTrue);
    expect(tracker.correctionAt(190, audioDelay: double.nan).established, isFalse);
  });

  test('an interior rejected timestamp cannot combine with a later outlier to revoke a valid prediction', () {
    final tracker = TimelineTracker();
    expect(
      tracker.observe([anchor(0, 100, 104), anchor(1, 110, 114.1), anchor(2, 115, 117.5), anchor(3, 120, 124.2)]),
      isTrue,
    );
    expect(tracker.correctionAt(140).position.automaticDelay, closeTo(4.1, 1e-9));
    expect(tracker.observe([anchor(4, 135, 136.4)]), isFalse);
    expect(tracker.correctionAt(145).position.automaticDelay, closeTo(4.1, 1e-9));
  });

  test('a sparse early cue survives a later constant cluster to establish drift', () {
    final tracker = TimelineTracker();
    // Numeric observations from the initial real-speech slowdown trial. A
    // constant fit cannot explain cue 2 together with the later cluster.
    expect(tracker.observe([anchor(2, 10.670, 11.775)]), isFalse);
    expect(tracker.observe([anchor(5, 62.455, 65.759)]), isFalse);
    expect(tracker.observe([anchor(7, 77.105, 81.203), anchor(8, 86.345, 90.723)]), isTrue);
    expect(tracker.map.segments.single.slope, 1);
    expect(tracker.observe([anchor(10, 109.755, 114.723), anchor(11, 115.355, 120.983)]), isTrue);
    expect(tracker.map.segments, hasLength(1));
    expect(tracker.map.segments.single.anchors, hasLength(6));
    expect(tracker.map.segments.single.slope, closeTo(25025 / 24000, 0.005));
  });

  test('audio delay moves the valid domain and composes correctly with affine timing', () {
    const slope = 25 / 23.976;
    final tracker = TimelineTracker()
      ..observe([for (var i = 0; i < 8; i++) anchor(i, 100 + i * 20, slope * (100 + i * 20) + 4)]);
    tracker.discontinuity();
    for (final delay in [-2.0, 0.0, 3.0]) {
      final videoTime = slope * 150 + 4 + delay;
      final correction = tracker.correctionAt(videoTime, audioDelay: delay);
      expect(correction.position.subtitleTime, closeTo(150, 1e-9));
      expect(correction.position.automaticDelay, closeTo(videoTime - 150, 1e-9));
      expect(correction.predicted, isFalse);
      expect(tracker.correctionAt(slope * 99 + 4 + delay, audioDelay: delay).position.kind, TimelineRegionKind.unknown);
    }
    expect(tracker.correctionAt(150, audioDelay: double.nan).position.kind, TimelineRegionKind.unknown);
  });

  test('combined observations cannot bridge a long interval without evidence', () {
    final tracker = TimelineTracker()..observe([anchor(0, 100, 104), anchor(1, 110, 114)]);
    expect(tracker.observe([anchor(2, 500, 504), anchor(3, 510, 514)]), isTrue);
    expect(tracker.map.segments, hasLength(2));
    expect(tracker.map.atMedia(300).kind, TimelineRegionKind.unknown);
    expect(tracker.correctionAt(300).position.kind, TimelineRegionKind.unknown);
  });

  test('acquisition requires independent cues; prediction stays outside the learned map', () {
    final tracker = TimelineTracker();
    expect(tracker.observe([anchor(0, 100, 104)]), isFalse);
    expect(tracker.observe([anchor(0, 100, 104)]), isFalse);
    expect(tracker.correctionAt(106).position.kind, TimelineRegionKind.unknown);
    expect(tracker.observe([anchor(1, 110, 114)]), isTrue);
    expect(tracker.correctionAt(108).position.automaticDelay, 4);
    expect(tracker.correctionAt(108).predicted, isFalse);
    expect(tracker.correctionAt(120).position.automaticDelay, 4);
    expect(tracker.correctionAt(120).predicted, isTrue);
    expect(tracker.map.atMedia(120).kind, TimelineRegionKind.unknown);
    expect(tracker.correctionAt(235).position.kind, TimelineRegionKind.unknown);
    expect(tracker.correctionAt(double.nan).position.kind, TimelineRegionKind.unknown);
  });

  test('seek retains known regions but revokes every extrapolation', () {
    final tracker = TimelineTracker()..observe([anchor(0, 100, 104), anchor(1, 110, 114)]);
    tracker.discontinuity();
    expect(tracker.correctionAt(108).position.automaticDelay, 4);
    expect(tracker.correctionAt(120).position.kind, TimelineRegionKind.unknown);
    expect(tracker.observe([anchor(2, 200, 290), anchor(3, 210, 300)]), isTrue);
    expect(tracker.map.segments.length, 2);
    expect(tracker.correctionAt(108).position.automaticDelay, 4);
    expect(tracker.correctionAt(295).position.automaticDelay, 90);
    expect(tracker.correctionAt(180).position.kind, TimelineRegionKind.unknown);
  });

  test('three spaced windows learn cadence drift without erasing earlier evidence', () {
    const slope = 25 / 23.976;
    final tracker = TimelineTracker();
    for (var window = 0; window < 3; window++) {
      final start = 100.0 + window * 30;
      expect(
        tracker.observe([
          anchor(window * 2, start, slope * start + 4),
          anchor(window * 2 + 1, start + 10, slope * (start + 10) + 4),
        ]),
        isTrue,
      );
    }
    expect(tracker.map.segments, hasLength(1));
    expect(tracker.map.segments.single.slope, closeTo(slope, 1e-9));
    expect(tracker.map.segments.single.anchors, hasLength(6));
    final media = slope * 200 + 4;
    expect(tracker.correctionAt(media).position.automaticDelay, closeTo(media - 200, 1e-9));
    tracker.discontinuity();
    expect(tracker.correctionAt(slope * 130 + 4).position.subtitleTime, closeTo(130, 1e-9));
  });

  test('a confirmed offset jump adds a new region and leaves its boundary unknown', () {
    final tracker = TimelineTracker()..observe([anchor(0, 100, 104), anchor(1, 110, 114)]);
    expect(tracker.observe([anchor(2, 130, 164), anchor(3, 140, 174)]), isTrue);
    expect(tracker.map.segments, hasLength(2));
    expect(tracker.map.atMedia(140).kind, TimelineRegionKind.unknown);
    expect(tracker.correctionAt(140).position.kind, TimelineRegionKind.unknown);
    expect(tracker.correctionAt(170).position.automaticDelay, 34);
    expect(tracker.correctionAt(108).position.automaticDelay, 4);
  });

  test('overlapping incompatible edition cannot overwrite history or prolong prediction', () {
    final tracker = TimelineTracker()..observe([anchor(0, 100, 104), anchor(1, 120, 124)]);
    expect(tracker.observe([anchor(2, 110, 150), anchor(3, 125, 165)]), isFalse);
    expect(tracker.map.segments, hasLength(1));
    expect(tracker.correctionAt(110).position.automaticDelay, 4);
    expect(tracker.correctionAt(170).position.kind, TimelineRegionKind.unknown);
  });

  test('one false phrase cannot move the correction and a new media clears history', () {
    final tracker = TimelineTracker()..observe([anchor(0, 100, 104), anchor(1, 110, 114)]);
    expect(tracker.observe([anchor(2, 130, 230)]), isFalse);
    expect(tracker.correctionAt(120).position.automaticDelay, 4);
    tracker.clear();
    expect(tracker.map.segments, isEmpty);
    expect(tracker.correctionAt(108).position.kind, TimelineRegionKind.unknown);
    expect(tracker.observe([anchor(3, 140, 240)]), isFalse);
  });
}
