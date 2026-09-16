import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';

SubtitleAnchor anchor(int cue, double subtitle, double media, {String? phrase}) =>
    SubtitleAnchor(cue, subtitle, media, 0.35, phrase ?? 'unique dialogue number $cue');

TimelineSegment segment(double start, double end, double offset) => TimelineSegment(
  subtitleStart: start,
  subtitleEnd: end,
  slope: 1,
  offset: offset,
  uncertainty: 0.35,
  anchors: [anchor(0, start, start + offset), anchor(1, end - 1, end - 1 + offset)],
);

void main() {
  const fitter = TimelineFitter();
  group('robust fitting', () {
    for (final offset in [0.0, 3.75, -12.0, 90.0]) {
      test('constant offset $offset is bounded by observed anchors', () {
        final fitted = fitter.fit([anchor(0, 100, 100 + offset), anchor(1, 110, 110 + offset)])!;
        expect(fitted.slope, 1);
        expect(fitted.offset, offset);
        final map = TimelineMap(segments: [fitted]);
        expect(map.atMedia(105 + offset).automaticDelay, closeTo(offset, 1e-9));
        expect(map.atMedia(99 + offset).kind, TimelineRegionKind.unknown);
        expect(map.atMedia(111 + offset).kind, TimelineRegionKind.unknown);
      });
    }

    test('23.976/25 drift survives one outlier without stretching its domain', () {
      const slope = 25 / 23.976;
      final observations = [
        for (var i = 0; i < 9; i++) anchor(i, 100 + i * 20, slope * (100 + i * 20) + 4 + (i == 8 ? 30 : 0)),
      ];
      final fitted = fitter.fit(observations)!;
      expect(fitted.slope, closeTo(slope, 1e-10));
      expect(fitted.offset, closeTo(4, 1e-10));
      expect(fitted.anchors.length, 8);
      expect(fitted.subtitleEnd, closeTo(240.000001, 1e-9));
      final media = fitted.mediaFor(200);
      expect(TimelineMap(segments: [fitted]).atMedia(media).automaticDelay, closeTo(media - 200, 1e-9));
    });

    test('one short window cannot learn a slope', () {
      final fitted = fitter.fit([for (var i = 0; i < 8; i++) anchor(i, 100 + i * 1.0, 104 + i * 1.02)])!;
      expect(fitted.slope, 1);
    });

    test('six phrases over sixty seconds are required for cadence correction', () {
      final fitted = fitter.fit([for (var i = 0; i < 5; i++) anchor(i, 100 + i * 20, 105 + i * 21.0)]);
      expect(fitted, isNull);
    });

    test('reused cues or equivalent phrases do not become confirmations', () {
      expect(fitter.fit([anchor(0, 100, 105), anchor(0, 110, 115)]), isNull);
      expect(
        fitter.fit([
          anchor(0, 100, 105, phrase: 'Please stop right there!'),
          anchor(1, 110, 115, phrase: 'PLEASE  stop right there.'),
        ]),
        isNull,
      );
    });

    test('ambiguous incompatible editions do not produce a lock', () {
      expect(fitter.fit([anchor(0, 100, 110), anchor(1, 110, 120), anchor(2, 120, 160), anchor(3, 130, 170)]), isNull);
    });

    test('invalid values are rejected before fitting', () {
      expect(fitter.fit([anchor(0, double.nan, 10), anchor(1, 20, double.infinity)]), isNull);
      expect(fitter.fit([anchor(0, -5, 1), anchor(1, 10, 16)]), isNull);
    });
  });

  group('segment domains and gaps', () {
    test('refinement keeps the latest accepted cue timing and unreobserved historical anchors', () {
      final historical = [anchor(0, 100, 104), anchor(1, 110, 114), anchor(2, 120, 124)];
      final earlier = TimelineMap(segments: [fitter.fit(historical)!]);
      final updated = anchor(1, 110, 114.2);
      final candidate = fitter.fit([historical[0], updated, anchor(3, 130, 134.2)])!;
      final refined = earlier.withSegment(candidate).segments.single;
      expect(refined.anchors.singleWhere((a) => a.cue == 1), same(updated));
      expect(refined.anchors.singleWhere((a) => a.cue == 2), same(historical[2]));
      expect(refined.anchors.map((a) => a.cue).toSet(), {0, 1, 2, 3});
      expect(earlier.segments.single.anchors[1].mediaTime, 114);
    });

    test('video insertion preserves earlier segment when seeking backward', () {
      final map = TimelineMap(
        segments: [segment(0, 20, 0), segment(20, 40, 90)],
        gaps: [TimelineGap(TimelineRegionKind.videoOnly, 20, 110)],
      );
      expect(map.atMedia(15).automaticDelay, 0);
      expect(map.atMedia(20).kind, TimelineRegionKind.videoOnly);
      expect(map.atMedia(109.99).kind, TimelineRegionKind.videoOnly);
      expect(map.atMedia(110).automaticDelay, 90);
      expect(map.atMedia(119).subtitleTime, 29);
      expect(map.atMedia(15).automaticDelay, 0);
      expect(map.atMedia(130).kind, TimelineRegionKind.unknown);
    });

    test('deleted subtitle portion uses source bounds and half-open boundaries', () {
      final map = TimelineMap(
        segments: [segment(0, 20, 0), segment(50, 80, -30)],
        gaps: [TimelineGap(TimelineRegionKind.subtitleOnly, 20, 50)],
      );
      expect(map.atSubtitle(20), TimelineRegionKind.subtitleOnly);
      expect(map.atSubtitle(49.99), TimelineRegionKind.subtitleOnly);
      expect(map.atSubtitle(50), TimelineRegionKind.aligned);
      expect(map.atMedia(20).subtitleTime, 50);
    });

    test('an unobserved interval is unknown even between confident segments', () {
      final map = TimelineMap(segments: [segment(0, 20, 0), segment(40, 60, 0)]);
      expect(map.atMedia(30).kind, TimelineRegionKind.unknown);
      expect(map.atSubtitle(30), TimelineRegionKind.unknown);
    });

    test('overlaps and reversed scene order are rejected', () {
      expect(() => TimelineMap(segments: [segment(0, 20, 0), segment(10, 30, 0)]), throwsArgumentError);
      expect(() => TimelineMap(segments: [segment(0, 20, 100), segment(20, 40, 0)]), throwsArgumentError);
      expect(
        () => TimelineMap(segments: [segment(0, 20, 0)], gaps: [TimelineGap(TimelineRegionKind.videoOnly, 10, 30)]),
        throwsArgumentError,
      );
    });

    test('learning a later region retains the earlier region for backward seeks', () {
      final earlier = TimelineMap(segments: [segment(10, 30, 4)]);
      final later = earlier.withSegment(segment(50, 70, 90));
      expect(later.atMedia(150).automaticDelay, 90);
      expect(later.atMedia(20).automaticDelay, 4);
      expect(earlier.segments.length, 1);
      expect(later.atMedia(45).kind, TimelineRegionKind.unknown);
    });

    test('a refinement must retain and explain all previously learned evidence', () {
      final earlier = TimelineMap(segments: [segment(10, 30, 4)]);
      final refined = earlier.withSegment(segment(10, 60, 4.2));
      expect(refined.segments.length, 1);
      expect(refined.atMedia(45).automaticDelay, closeTo(4.2, 1e-9));
      expect(() => earlier.withSegment(segment(20, 60, 4)), throwsArgumentError);
      expect(() => earlier.withSegment(segment(10, 60, 90)), throwsArgumentError);
      expect(earlier.atMedia(20).automaticDelay, 4);
    });

    test('nonfinite or inconsistent anchors cannot enter a segment', () {
      expect(
        () => TimelineSegment(
          subtitleStart: 10,
          subtitleEnd: 30,
          slope: 1,
          offset: 0,
          uncertainty: 0.35,
          anchors: [anchor(0, 10, 10), anchor(1, double.nan, 20)],
        ),
        throwsArgumentError,
      );
      expect(
        () => TimelineSegment(
          subtitleStart: 10,
          subtitleEnd: 30,
          slope: 1,
          offset: 0,
          uncertainty: 0.35,
          anchors: [anchor(0, 10, 10), anchor(1, 20, 25)],
        ),
        throwsArgumentError,
      );
    });
  });
}
