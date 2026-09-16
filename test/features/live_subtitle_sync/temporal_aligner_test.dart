import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/native_bindings.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/transcript_matcher.dart';

void main() {
  const phrases = ['Please bring the silver lantern', 'Walk across that wooden bridge'];
  final index = SubtitleIndex(
    ParsedSubtitles(SubtitleEncoding.utf8, [
      for (var i = 0; i < phrases.length; i++)
        SubtitleCue(
          ordinal: i,
          sourceId: null,
          start: Duration(seconds: 2 + i * 5),
          end: Duration(seconds: 6 + i * 5),
          text: phrases[i],
          timingSuffix: '',
        ),
    ]),
  );
  NativeTranscript transcript(double offset, {bool timestamps = true}) =>
      NativeTranscript(1, 2, offset, offset + 15, 0.2, [
        for (var i = 0; i < phrases.length; i++)
          NativeTranscriptSegment(phrases[i], offset + 2 + i * 5, offset + 6 + i * 5, [
            for (var w = 0; w < 5; w++)
              NativeTranscriptToken(
                ' ${phrases[i].split(' ')[w]}',
                offset + 2 + i * 5 + w * 0.5,
                offset + 2.3 + i * 5 + w * 0.5,
                0.95,
                timestamps,
              ),
          ]),
      ]);
  final passage = const TranscriptMatcher().find(phrases.join(' '), index).passage!;

  test('timestamps come from matched cue beginnings, with signed media offsets', () {
    for (final offset in [0.0, 90.0, -1.5]) {
      final anchors = const TemporalAligner().anchors(transcript(offset), index, passage);
      expect(anchors, hasLength(2));
      expect(anchors.map((anchor) => anchor.offset), everyElement(closeTo(offset, 1e-8)));
      expect(ConstantOffsetEstimator().add(anchors), closeTo(offset, 1e-8));
      expect(anchors.every((anchor) => anchor.uncertainty >= 0.35), isTrue);
    }
  });

  test('text recognition without timestamps cannot become an anchor', () {
    expect(const TemporalAligner().anchors(transcript(90, timestamps: false), index, passage), isEmpty);
  });

  test('repeated windows and phrases cannot confirm a large correction', () {
    final estimator = ConstantOffsetEstimator();
    const first = SubtitleAnchor(0, 2, 92, 0.35, 'please bring the');
    expect(estimator.add([first]), isNull);
    expect(estimator.add([first]), isNull);
    expect(estimator.add([const SubtitleAnchor(1, 8, 98, 0.35, 'please bring the')]), isNull);
    expect(estimator.add([const SubtitleAnchor(1, 8, 98, 0.35, 'walk across that')]), 90);
  });

  test('inconsistent editions and uncertain timing do not lock', () {
    expect(
      ConstantOffsetEstimator().add([
        const SubtitleAnchor(0, 2, 92, 0.35, 'first distinct line'),
        const SubtitleAnchor(1, 8, 18, 0.35, 'second distinct line'),
      ]),
      isNull,
    );
    expect(
      ConstantOffsetEstimator().add([
        const SubtitleAnchor(0, 2, 92, 2, 'first distinct line'),
        const SubtitleAnchor(1, 8, 98, 2, 'second distinct line'),
      ]),
      isNull,
    );
  });
}
