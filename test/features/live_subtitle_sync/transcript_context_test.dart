import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/native_bindings.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/features/live_subtitle_sync/transcript_context.dart';
import 'package:plezy/features/live_subtitle_sync/transcript_matcher.dart';

NativeTranscript window(
  double start,
  double end,
  String phrase,
  double speech, {
  int generation = 1,
  int continuity = 2,
}) => NativeTranscript(generation, continuity, start, end, 0.1, [
  NativeTranscriptSegment(phrase, speech, speech + 2, [
    for (var i = 0; i < phrase.split(' ').length; i++)
      NativeTranscriptToken(' ${phrase.split(' ')[i]}', speech + i * 0.4, speech + i * 0.4 + 0.3, 0.95, true),
  ]),
]);

void main() {
  final index = SubtitleIndex(
    ParsedSubtitles(SubtitleEncoding.utf8, [
      for (final (i, time, text) in [(0, 2, 'Carry the lantern'), (1, 7, 'Cross the bridge')])
        SubtitleCue(
          ordinal: i,
          sourceId: null,
          start: Duration(seconds: time),
          end: Duration(seconds: time + 2),
          text: text,
          timingSuffix: '',
        ),
    ]),
  );

  test('two short adjacent windows identify a passage without lowering match thresholds', () {
    final context = TranscriptContext();
    final first = window(90, 96, 'Carry the lantern', 92);
    final second = window(96.2, 102, 'Cross the bridge', 97);
    expect(matchTranscriptEvidence(first, index).match.status, TranscriptMatchStatus.insufficientDialogue);
    expect(matchTranscriptEvidence(second, index).match.status, TranscriptMatchStatus.insufficientDialogue);
    expect(context.add(first), isNull);
    final evidence = matchTranscriptEvidence(second, index, context: context.add(second));
    expect(evidence.windowCount, 2);
    expect(evidence.match.status, TranscriptMatchStatus.matched);
    expect(evidence.anchors.map((anchor) => anchor.mediaTime), [92, 97]);
    expect(const TimelineFitter().fit(evidence.anchors)?.offset, 90);
  });

  test('context preserves a window-edge timestamp rejection', () {
    final context = TranscriptContext()..add(window(90, 96, 'Carry the lantern', 92));
    final second = window(97, 103, 'Cross the bridge', 97);
    final evidence = matchTranscriptEvidence(second, index, context: context.add(second));
    expect(evidence.match.status, TranscriptMatchStatus.matched);
    expect(evidence.anchors.map((anchor) => anchor.cue), [0]);
    expect(const TimelineFitter().fit(evidence.anchors)?.offset, isNull);
  });

  test('overlapped audio is not counted twice', () {
    final context = TranscriptContext()..add(window(90, 99, 'Carry the lantern', 97));
    expect(context.add(window(96, 108, 'Carry the lantern', 97)), isNull);
  });

  test('DTW token overlap is rejected even when coarse segment bounds do not overlap', () {
    final previous = NativeTranscript(1, 2, 90, 100, 0.1, [
      NativeTranscriptSegment('Carry the lantern', 92, 94, [
        const NativeTranscriptToken(' Carry', 92, 92.3, 0.95, true),
        const NativeTranscriptToken(' the', 92.4, 92.7, 0.95, true),
        const NativeTranscriptToken(' lantern', 95, 97, 0.95, true),
      ]),
    ]);
    final context = TranscriptContext()..add(previous);
    expect(context.add(window(96, 108, 'Cross the bridge', 98)), isNull);
  });

  test('a seek or dropped PCM breaks the textual context', () {
    for (final replacement in [
      window(96, 102, 'Cross the bridge', 97, generation: 2),
      window(96, 102, 'Cross the bridge', 97, continuity: 3),
      window(100, 112, 'Cross the bridge', 101),
    ]) {
      final context = TranscriptContext()..add(window(90, 96, 'Carry the lantern', 92));
      expect(context.add(replacement), isNull);
    }
  });

  test('repeated results cannot become independent confirmations or replace newer context', () {
    final first = window(90, 96, 'Carry the lantern', 92);
    final context = TranscriptContext()..add(first);
    expect(context.add(first), isNull);
    expect(context.add(window(80, 89, 'Unrelated old words', 82)), isNull);
    final combined = context.add(window(96, 102, 'Cross the bridge', 97))!;
    expect(combined.segments.first.text, 'Carry the lantern');
  });

  test('only two raw windows are retained, without recursive accumulation', () {
    final context = TranscriptContext()..add(window(90, 96, 'Carry the lantern', 92));
    context.add(window(96, 102, 'Cross the bridge', 97));
    final combined = context.add(window(102, 108, 'Find the river', 104))!;
    expect(combined.windowStart, 96);
    expect(combined.segments.map((segment) => segment.text), ['Cross the bridge', 'Find the river']);
    context.clear();
    expect(context.add(window(108, 114, 'Leave the village', 110)), isNull);
  });

  test('an invalid window clears the context', () {
    final context = TranscriptContext()..add(window(90, 96, 'Carry the lantern', 92));
    expect(context.add(window(double.nan, 100, 'Invalid time value', 97)), isNull);
    expect(context.add(window(96, 102, 'Cross the bridge', 97)), isNull);
  });

  test('repeating a short phrase does not manufacture a second matching cue', () {
    final context = TranscriptContext()..add(window(90, 96, 'Carry the lantern', 92));
    final repeated = window(96, 102, 'Carry the lantern', 97);
    final evidence = matchTranscriptEvidence(repeated, index, context: context.add(repeated));
    expect(evidence.match.status, isNot(TranscriptMatchStatus.matched));
    expect(evidence.anchors, isEmpty);
  });

  test('contiguous dialogue can match without accepting unrelated ASR text around it', () {
    final source = NativeTranscript(1, 2, 90, 105, 0.1, [
      ...window(90, 105, 'Unrelated invented background words', 90.2).segments,
      ...window(90, 105, 'Carry the lantern', 92).segments,
      ...window(90, 105, 'Cross the bridge', 97).segments,
      ...window(90, 105, 'More unrelated background words', 101).segments,
    ]);
    final whole = const TranscriptMatcher().find(source.segments.map((segment) => segment.text).join(' '), index);
    expect(whole.status, isNot(TranscriptMatchStatus.matched));
    final evidence = matchTranscriptEvidence(source, index);
    expect(evidence.segmented, isTrue);
    expect(evidence.anchors.map((anchor) => anchor.cue), [0, 1]);
    expect(const TimelineFitter().fit(evidence.anchors)?.offset, 90);
  });

  test('group searches retain conflicting timing evidence for rejection', () {
    final expanded = SubtitleIndex(
      ParsedSubtitles(SubtitleEncoding.utf8, [
        for (final (i, time, text) in [
          (0, 2, 'Carry the lantern'),
          (1, 7, 'Cross the bridge'),
          (2, 22, 'Find the river'),
          (3, 27, 'Leave the village'),
        ])
          SubtitleCue(
            ordinal: i,
            sourceId: null,
            start: Duration(seconds: time),
            end: Duration(seconds: time + 2),
            text: text,
            timingSuffix: '',
          ),
      ]),
    );
    final source = NativeTranscript(1, 2, 90, 120, 0.1, [
      ...window(90, 120, 'Unrelated introductory background words', 90.2).segments,
      ...window(90, 120, 'Carry the lantern', 92).segments,
      ...window(90, 120, 'Cross the bridge', 97).segments,
      ...window(90, 120, 'Unrelated background interruption with many unrecognized words', 100).segments,
      ...window(90, 120, 'Find the river', 108).segments,
      ...window(90, 120, 'Leave the village', 113).segments,
    ]);
    final evidence = matchTranscriptEvidence(source, expanded);
    expect(evidence.segmented, isTrue);
    expect(evidence.anchors.length, 4);
    expect(const TimelineFitter().fit(evidence.anchors)?.offset, isNull);
  });

  test('an individually valid match stays preferred over unrelated context', () {
    final current = window(90, 105, 'Carry the lantern Cross the bridge', 92);
    final evidence = matchTranscriptEvidence(current, index, context: window(80, 105, 'Entirely unrelated speech', 85));
    expect(evidence.windowCount, 1);
    expect(evidence.match.status, TranscriptMatchStatus.matched);
  });
}
