import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';

SubtitleAnchor anchor(int cue, double subtitle, double media) =>
    SubtitleAnchor(cue, subtitle, media, 0.35, 'distinct phrase number $cue');

void main() {
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
