import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/native_bindings.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/transcript_matcher.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';

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
  NativeTranscript transcript(
    double offset, {
    bool timestamps = true,
    NativeSpeechSupport speech = NativeSpeechSupport.unknown,
  }) => NativeTranscript(1, 2, offset, offset + 15, 0.2, [
    for (var i = 0; i < phrases.length; i++)
      NativeTranscriptSegment(phrases[i], offset + 2 + i * 5, offset + 6 + i * 5, [
        for (var w = 0; w < 5; w++)
          NativeTranscriptToken(
            ' ${phrases[i].split(' ')[w]}',
            offset + 2 + i * 5 + w * 0.5,
            offset + 2.3 + i * 5 + w * 0.5,
            0.95,
            timestamps,
            speechSupport: speech,
          ),
      ]),
  ]);
  final passage = const TranscriptMatcher().find(phrases.join(' '), index).passage!;

  test('speech support rejects silence anchors without changing text or inventing timing', () {
    for (final support in NativeSpeechSupport.values) {
      final source = transcript(90, speech: support);
      final match = const TranscriptMatcher().find(phrases.join(' '), index);
      expect(match.status, TranscriptMatchStatus.matched);
      final rejected = <String, int>{};
      final anchors = const TemporalAligner().anchors(source, index, match.passage!, rejectionCounts: rejected);
      if (support == NativeSpeechSupport.unsupported) {
        expect(anchors, isEmpty);
        expect(rejected['beginningUnsupportedSpeech'], 2);
      } else {
        expect(anchors.map((a) => a.offset), [90, 90]);
        expect(anchors.map((a) => a.uncertainty), [0.35, 0.35]);
        expect(rejected, isEmpty);
      }
    }
  });

  NativeTranscript alteredFirst(List<String> words, {int? untimed, int? reversed}) =>
      NativeTranscript(1, 2, 90, 105, 0.2, [
        NativeTranscriptSegment(words.join(' '), 92, 96, [
          for (var i = 0; i < words.length; i++)
            NativeTranscriptToken(
              ' ${words[i]}',
              i == reversed ? 91.5 : 92 + i * 0.5,
              i == reversed ? 91.8 : 92.3 + i * 0.5,
              0.95,
              i != untimed,
            ),
        ]),
        transcript(90).segments[1],
      ]);

  List<SubtitleAnchor> align(NativeTranscript source) {
    final match = const TranscriptMatcher().find(source.segments.map((s) => s.text).join(' '), index);
    expect(match.status, TranscriptMatchStatus.matched);
    return const TemporalAligner().anchors(source, index, match.passage!);
  }

  NativeTranscript punctuatedFirst({
    double wordScore = 0.95,
    bool wordTimestamp = true,
    bool punctuationTimed = false,
  }) => NativeTranscript(1, 2, 90, 105, 0.2, [
    NativeTranscriptSegment('“Please,” bring the silver lantern', 92, 96, [
      // Punctuation has no acoustic onset. Its absent/low-confidence DTW
      // metadata must not replace or invalidate the actual word's point.
      NativeTranscriptToken('“', 91, 91.02, punctuationTimed ? 0.95 : 0.01, punctuationTimed),
      NativeTranscriptToken('Please', 92, 92.3, wordScore, wordTimestamp),
      NativeTranscriptToken(',”', 91, 91.02, punctuationTimed ? 0.95 : 0.01, punctuationTimed),
      for (var i = 1; i < 5; i++)
        NativeTranscriptToken(' ${phrases.first.split(' ')[i]}', 92 + i * 0.5, 92.3 + i * 0.5, 0.95, true),
    ]),
    transcript(90).segments[1],
  ]);

  test('punctuation-only tokens do not invalidate or move the spoken cue beginning', () {
    for (final timed in [false, true]) {
      final source = punctuatedFirst(punctuationTimed: timed);
      final anchors = align(source);
      expect(anchors, hasLength(2));
      expect(anchors.first.mediaTime, 92);
      expect(anchors.first.offset, 90);
      expect(anchors.first.uncertainty, 0.35);
      expect(source.segments.first.text, '“Please,” bring the silver lantern');
    }
  });

  test('ignoring punctuation never rescues an unreliable lexical token', () {
    for (final source in [punctuatedFirst(wordScore: 0.1), punctuatedFirst(wordTimestamp: false)]) {
      final anchors = align(source);
      expect(anchors, hasLength(1));
      expect(anchors.single.cue, 1);
    }
  });

  test('one interior substitution has four exact flanks and retains canonical cue identity', () {
    final anchors = align(alteredFirst(['Please', 'bring', 'that', 'silver', 'lantern']));
    expect(anchors, hasLength(2));
    expect(anchors.first.offset, 90);
    expect(anchors.first.phrase, 'please bring the');
    expect(anchors.first.phrase, const TemporalAligner().anchors(transcript(90), index, passage).first.phrase);
  });

  test('an abbreviated title retains the original cue-start token timestamp', () {
    final subtitles = SubtitleIndex(
      ParsedSubtitles(SubtitleEncoding.utf8, [
        const SubtitleCue(
          ordinal: 0,
          sourceId: null,
          start: Duration(seconds: 2),
          end: Duration(seconds: 6),
          text: 'Mister Brown carried the silver lantern',
          timingSuffix: '',
        ),
      ]),
    );
    const text = 'Mr. Brown carried the silver lantern';
    final source = NativeTranscript(1, 1, 90, 105, 0.1, [
      NativeTranscriptSegment(text, 92, 96, [
        for (var i = 0; i < text.split(' ').length; i++)
          NativeTranscriptToken(' ${text.split(' ')[i]}', 92 + i * 0.5, 92.2 + i * 0.5, 0.95, true),
      ]),
    ]);
    final passage = const TranscriptMatcher().find(text, subtitles).passage!;
    final anchors = const TemporalAligner().anchors(source, subtitles, passage);
    expect(anchors, hasLength(1));
    expect(anchors.single.offset, 90);
    expect(anchors.single.phrase, 'mister brown carried');
  });

  test('substitution recovery cannot accept missing beginnings, shifted words or bad times', () {
    for (final source in [
      alteredFirst(['Kindly', 'bring', 'the', 'silver', 'lantern']),
      alteredFirst(['Please', 'bring', 'those', 'gold', 'lantern']),
      alteredFirst(['Please', 'bring', 'silver', 'lantern']),
      alteredFirst(['Please', 'bring', 'really', 'the', 'silver', 'lantern']),
      alteredFirst(['Please', 'bring', 'that', 'silver', 'lantern'], untimed: 2),
      alteredFirst(['Please', 'bring', 'that', 'silver', 'lantern'], reversed: 2),
      alteredFirst(['Please', 'bring', 'please', 'silver', 'lantern']),
    ]) {
      expect(align(source).map((a) => a.cue), [1]);
    }
  });

  test('timestamps come from matched cue beginnings, with signed media offsets', () {
    for (final offset in [0.0, 90.0, -1.5]) {
      final anchors = const TemporalAligner().anchors(transcript(offset), index, passage);
      expect(anchors, hasLength(2));
      expect(anchors.map((anchor) => anchor.offset), everyElement(closeTo(offset, 1e-8)));
      expect(const TimelineFitter().fit(anchors)?.offset, closeTo(offset, 1e-8));
      expect(anchors.every((anchor) => anchor.uncertainty >= 0.35), isTrue);
    }
  });

  test('text recognition without timestamps cannot become an anchor', () {
    final rejected = <String, int>{};
    expect(
      const TemporalAligner().anchors(transcript(90, timestamps: false), index, passage, rejectionCounts: rejected),
      isEmpty,
    );
    expect(rejected, {'beginningInvalidTimestamp': 2});
    rejected.clear();
    expect(const TemporalAligner().anchors(transcript(90), index, passage, rejectionCounts: rejected), hasLength(2));
    expect(rejected, isEmpty);
  });

  test('repeated windows and phrases cannot confirm a large correction', () {
    final tracker = TimelineTracker();
    const first = SubtitleAnchor(0, 2, 92, 0.35, 'please bring the');
    expect(tracker.observe([first]), isFalse);
    expect(tracker.observe([first]), isFalse);
    expect(tracker.observe([const SubtitleAnchor(1, 8, 98, 0.35, 'please bring the')]), isFalse);
    expect(tracker.observe([const SubtitleAnchor(1, 8, 98, 0.35, 'walk across that')]), isTrue);
    expect(tracker.correctionAt(100).position.automaticDelay, 90);
  });

  test('inconsistent editions and uncertain timing do not lock', () {
    expect(
      const TimelineFitter().fit([
        const SubtitleAnchor(0, 2, 92, 0.35, 'first distinct line'),
        const SubtitleAnchor(1, 8, 18, 0.35, 'second distinct line'),
      ]),
      isNull,
    );
    expect(
      const TimelineFitter().fit([
        const SubtitleAnchor(0, 2, 92, 2, 'first distinct line'),
        const SubtitleAnchor(1, 8, 98, 2, 'second distinct line'),
      ]),
      isNull,
    );
  });
}
