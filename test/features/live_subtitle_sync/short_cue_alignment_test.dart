import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/native_bindings.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/transcript_matcher.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';

void main() {
  const captions = ['Amber lantern', 'across silent', 'stone bridge', 'under evening', 'winter stars', 'beside river'];

  List<SubtitleAnchor> align({
    List<String> cues = captions,
    List<int>? starts,
    int dropCues = 0,
    int? unreliableWord,
    int? unsupportedWord,
    int? delayedWord,
    bool substituteContext = false,
  }) {
    final index = SubtitleIndex(
      ParsedSubtitles(SubtitleEncoding.utf8, [
        for (var i = 0; i < cues.length; i++)
          SubtitleCue(
            ordinal: i,
            sourceId: null,
            start: Duration(seconds: starts?[i] ?? 2 + i * 2),
            end: Duration(seconds: (starts?[i] ?? 2 + i * 2) + 2),
            text: cues[i],
            timingSuffix: '',
          ),
      ]),
    );
    final segments = <NativeTranscriptSegment>[];
    var wordOrdinal = 0;
    for (var i = 0; i < cues.length; i++) {
      final words = cues[i].split(' ');
      final begin = 90.0 + (starts?[i] ?? 2 + i * 2);
      final tokens = <NativeTranscriptToken>[];
      for (var w = 0; w < words.length; w++, wordOrdinal++) {
        final start = wordOrdinal == delayedWord ? 99.0 : begin + w * 0.4;
        final text = substituteContext && wordOrdinal == 2 ? 'different' : words[w];
        tokens.add(
          NativeTranscriptToken(
            ' $text',
            start,
            start + 0.2,
            wordOrdinal == unreliableWord ? 0.1 : 0.95,
            true,
            speechSupport: wordOrdinal == unsupportedWord
                ? NativeSpeechSupport.unsupported
                : NativeSpeechSupport.supported,
          ),
        );
      }
      if (i >= dropCues) {
        segments.add(NativeTranscriptSegment(tokens.map((t) => t.text).join(), begin, begin + 2, tokens));
      }
    }
    final transcript = NativeTranscript(1, 1, 90, 105, 0.2, segments);
    final match = const TranscriptMatcher().find(segments.map((s) => s.text).join(' '), index);
    expect(match.status, TranscriptMatchStatus.matched);
    return const TemporalAligner().anchors(transcript, index, match.passage!);
  }

  test('short neighboring captions retain three-word evidence and the actual cue onset', () {
    final anchors = align();
    expect(anchors.map((a) => a.cue), [0, 2, 4]);
    expect(anchors.map((a) => a.mediaTime), [92, 96, 100]);
    expect(anchors.map((a) => a.offset), [90, 90, 90]);
    expect(anchors.map((a) => a.phrase), ['amber lantern across', 'stone bridge under', 'winter stars beside']);
    expect(const TimelineFitter().independentObservations(anchors), hasLength(3));
  });

  test('overlapping windows cannot turn borrowed context into independent anchors', () {
    final full = align();
    final cropped = align(dropCues: 1);
    expect(cropped.map((a) => a.cue), [2, 4]);
    expect(const TimelineFitter().independentObservations([...full, ...cropped]), hasLength(3));
  });

  test('a rejected short cue does not reassign its evidence to the next cue', () {
    expect(align(unreliableWord: 0).map((a) => a.cue), [2, 4]);
    expect(align(unsupportedWord: 0).map((a) => a.cue), [2, 4]);
  });

  test('borrowed words must remain exact and confident', () {
    expect(align(unreliableWord: 2).map((a) => a.cue), [2, 4]);
    expect(align(substituteContext: true).map((a) => a.cue), [2, 4]);
  });

  test('context across a long source gap is not borrowed', () {
    expect(align(starts: [2, 8, 9, 10, 11, 12]).map((a) => a.cue), [1, 3]);
  });

  test('a long or reversed media context cannot establish a short-cue anchor', () {
    expect(align(delayedWord: 2).map((a) => a.cue), [2, 4]);
  });

  test('existing long-cue evidence has priority over overlapping short context', () {
    expect(
      align(
        cues: ['Amber lantern', 'walk across the silver bridge', 'under evening', 'winter stars', 'beside river'],
      ).map((a) => a.cue),
      [1, 2],
    );
  });
}
