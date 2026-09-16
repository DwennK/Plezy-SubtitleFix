import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/audio_activity.dart';
import 'package:plezy/features/live_subtitle_sync/native_bindings.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/transcript_matcher.dart';

void main() {
  const previous = 'They walked beside the quiet river';
  const authored = 'Carefully place those silver lanterns beside wooden gates';
  const recognized = 'Clearly place those silver lanterns beside wooden gates';
  final index = SubtitleIndex(
    ParsedSubtitles(SubtitleEncoding.utf8, [
      const SubtitleCue(
        ordinal: 0,
        sourceId: null,
        start: Duration(seconds: 1),
        end: Duration(seconds: 4),
        text: previous,
        timingSuffix: '',
      ),
      const SubtitleCue(
        ordinal: 1,
        sourceId: null,
        start: Duration(seconds: 5),
        end: Duration(seconds: 10),
        text: authored,
        timingSuffix: '',
      ),
    ]),
  );
  const onset = AudioVoiceOnset(7.9, 10, 0.8, 1.2);
  NativeTranscript source({
    String current = recognized,
    bool firstTimestamp = true,
    bool leftTimestamp = true,
    int? weakRight,
    int? reversed,
    double start = 0,
    double end = 15,
    List<AudioVoiceOnset> onsets = const [onset],
  }) => NativeTranscript(1, 1, start, end, 0, [
    NativeTranscriptSegment(previous, 4, 7, [
      for (var i = 0; i < previous.split(' ').length; i++)
        NativeTranscriptToken(' ${previous.split(' ')[i]}', 4 + i * .5, 4.2 + i * .5, .9, i != 5 || leftTimestamp),
    ]),
    NativeTranscriptSegment(current, 8, 12, [
      for (var i = 0; i < current.split(' ').length; i++)
        NativeTranscriptToken(
          ' ${current.split(' ')[i]}',
          i == reversed ? 7 : 8 + i * .5,
          i == reversed ? 7.2 : 8.2 + i * .5,
          i == 0 || i == weakRight ? .2 : .9,
          i != 0 || firstTimestamp,
        ),
    ]),
  ], voiceOnsets: onsets);

  List<SubtitleAnchor> anchors(NativeTranscript input, {bool enabled = true}) {
    final match = const TranscriptMatcher().find(input.segments.map((s) => s.text).join(' '), index);
    expect(match.status, TranscriptMatchStatus.matched);
    return TemporalAligner(experimentalAcousticBeginnings: enabled).anchors(input, index, match.passage!);
  }

  bool recovered(NativeTranscript input) => anchors(input).any((a) => a.cue == 1);

  test('experiment needs both a uniquely matched passage and a corroborated onset', () {
    expect(anchors(source(), enabled: false).map((a) => a.cue), [0]);
    final result = anchors(source()).last;
    expect(result.cue, 1);
    expect(result.mediaTime, 7.9);
    expect(result.offset, closeTo(2.9, 1e-9));
    expect(result.phrase, 'carefully place those');
    expect(result.uncertainty, .5);
  });

  test('silence alone, an impulse, ambiguity and unobserved quiet cannot recover', () {
    for (final onsets in <List<AudioVoiceOnset>>[
      [],
      [const AudioVoiceOnset(7.9, 10, 0, 1.2)],
      [const AudioVoiceOnset(7.9, 10, .8, .02)],
      [onset, const AudioVoiceOnset(8.1, 8.2, .01, .02)],
      [const AudioVoiceOnset(7.5, 10, .8, 1.2)],
      [const AudioVoiceOnset(7.9, 8.1, .8, .1)],
      [const AudioVoiceOnset(7.9, 10, 20, 1.2)],
      [const AudioVoiceOnset(7.9, 10, .8, double.nan)],
      [const AudioVoiceOnset(7.9, 10, .8, 5)],
    ]) {
      expect(recovered(source(onsets: onsets)), isFalse);
    }
  });

  test('missing or shifted words and untrusted right flanks cannot recover', () {
    for (final input in [
      source(current: 'place those silver lanterns beside wooden gates'),
      source(current: 'Clearly really place those silver lanterns beside wooden gates'),
      source(current: 'Clearly place these silver lanterns beside wooden gates'),
      source(firstTimestamp: false),
      source(leftTimestamp: false),
      source(weakRight: 3),
      source(reversed: 3),
      source(start: 7.8),
      source(end: 9),
    ]) {
      expect(recovered(input), isFalse);
    }
  });

  test('acoustic evidence does not replace an exact but low-confidence first word', () {
    expect(recovered(source(current: authored)), isFalse);
  });
}
