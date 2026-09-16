import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';

SubtitleAnchor anchor(int cue, double subtitle, double media) =>
    SubtitleAnchor(cue, subtitle, media, 0.35, 'distinct phrase number $cue');

void main() {
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
