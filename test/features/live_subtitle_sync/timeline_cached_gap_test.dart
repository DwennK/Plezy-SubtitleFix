import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';

SubtitleAnchor anchor(int cue, double subtitle, double media) =>
    SubtitleAnchor(cue, subtitle, media, 0.35, 'distinct dialogue phrase $cue');

void main() {
  test('fresh dialogue can invalidate a wrong cached video-only region', () {
    final wrong = TimelineGap(TimelineRegionKind.videoOnly, 200, 260);
    final unrelated = TimelineGap(TimelineRegionKind.videoOnly, 350, 380);
    final tracker = TimelineTracker()..restore(TimelineMap(gaps: [wrong, unrelated]));
    expect(tracker.correctionAt(215).position.kind, TimelineRegionKind.videoOnly);
    expect(tracker.observe([anchor(0, 100, 210), anchor(1, 110, 220)]), isTrue);
    expect(tracker.map.gaps, [unrelated]);
    expect(tracker.correctionAt(215).position.kind, TimelineRegionKind.aligned);
    expect(tracker.correctionAt(215).position.automaticDelay, 110);
    expect(tracker.correctionAt(360).position.kind, TimelineRegionKind.videoOnly);
  });

  test('fresh source-cue matches can invalidate a wrong cached subtitle-only region', () {
    final wrong = TimelineGap(TimelineRegionKind.subtitleOnly, 100, 140);
    final unrelated = TimelineGap(TimelineRegionKind.subtitleOnly, 400, 440);
    final tracker = TimelineTracker()..restore(TimelineMap(gaps: [wrong, unrelated]));
    expect(tracker.map.atSubtitle(115), TimelineRegionKind.subtitleOnly);
    expect(tracker.observe([anchor(0, 110, 210), anchor(1, 120, 220)]), isTrue);
    expect(tracker.map.gaps, [unrelated]);
    expect(tracker.map.atSubtitle(115), TimelineRegionKind.aligned);
    expect(tracker.map.atSubtitle(420), TimelineRegionKind.subtitleOnly);
  });

  test('one cue, repeated evidence, and an outside cue cannot disprove a cached gap', () {
    final gap = TimelineGap(TimelineRegionKind.videoOnly, 200, 230);
    final tracker = TimelineTracker()..restore(TimelineMap(gaps: [gap]));
    final first = anchor(0, 100, 210);
    expect(tracker.observe([first]), isFalse);
    expect(tracker.observe([first]), isFalse);
    expect(tracker.observe([anchor(1, 140, 250)]), isFalse);
    expect(tracker.map.gaps, [gap]);
    expect(tracker.correctionAt(215).position.kind, TimelineRegionKind.videoOnly);
  });

  test('a fit crossing a cached gap without observed dialogue inside cannot erase it', () {
    final gap = TimelineGap(TimelineRegionKind.videoOnly, 210, 230);
    final tracker = TimelineTracker()..restore(TimelineMap(gaps: [gap]));
    expect(tracker.observe([anchor(0, 100, 200), anchor(1, 140, 240)]), isFalse);
    expect(tracker.map.gaps, [gap]);
  });

  test('a seek cannot combine separate unconfirmed cues into gap invalidation', () {
    final gap = TimelineGap(TimelineRegionKind.videoOnly, 200, 260);
    final tracker = TimelineTracker()..restore(TimelineMap(gaps: [gap]));
    expect(tracker.observe([anchor(0, 100, 210)]), isFalse);
    tracker.discontinuity();
    expect(tracker.observe([anchor(1, 110, 220)]), isFalse);
    expect(tracker.map.gaps, [gap]);
    expect(tracker.observe([anchor(2, 120, 230)]), isTrue);
    expect(tracker.map.gaps, isEmpty);
  });

  test('uncertain timestamps touching a video-gap boundary do not revoke it', () {
    final gap = TimelineGap(TimelineRegionKind.videoOnly, 200, 230);
    final tracker = TimelineTracker()..restore(TimelineMap(gaps: [gap]));
    expect(tracker.observe([anchor(0, 100, 200.1), anchor(1, 129.8, 229.9)]), isFalse);
    expect(tracker.map.gaps, [gap]);
  });

  test('the right subtitle boundary is outside the cached absence interval', () {
    final gap = TimelineGap(TimelineRegionKind.subtitleOnly, 100, 130);
    final tracker = TimelineTracker()..restore(TimelineMap(gaps: [gap]));
    expect(tracker.observe([anchor(0, 110, 210), anchor(1, 130, 230)]), isFalse);
    expect(tracker.map.gaps, [gap]);
  });
}
