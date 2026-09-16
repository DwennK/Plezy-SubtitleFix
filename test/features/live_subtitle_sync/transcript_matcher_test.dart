import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/text_normalization.dart';
import 'package:plezy/features/live_subtitle_sync/transcript_matcher.dart';

ParsedSubtitles document(List<String> lines) => ParsedSubtitles(SubtitleEncoding.utf8, [
  for (var i = 0; i < lines.length; i++)
    SubtitleCue(
      ordinal: i,
      sourceId: '1',
      start: Duration(seconds: i * 10),
      end: Duration(seconds: i * 10 + 5),
      text: lines[i],
      timingSuffix: '',
    ),
]);

void main() {
  const normalizer = DialogueNormalizer();
  const matcher = TranscriptMatcher();
  const dialogue = 'Please bring the silver lantern across the wooden bridge tonight';

  test('normalization handles Unicode, styles and safe contractions without rewriting source', () {
    expect(
      normalizer.words(
        'ALICE: <i>Ｗｅ’re</i> sure I can’t. I won’t! She’s ready.\n'
        '[door closes] {\\an8}We’ve found &lt;b&gt;gold&lt;/b&gt; &amp; silver.',
      ),
      [
        'we',
        'are',
        'sure',
        'i',
        'can',
        'not',
        'i',
        'will',
        'not',
        "she's",
        'ready',
        'we',
        'have',
        'found',
        'gold',
        'and',
        'silver',
      ],
    );
    expect(normalizer.words('♪ Never trust these lyrics ♪\n(laughing) Ordinary dialogue.'), ['ordinary', 'dialogue']);
    expect(normalizer.words('We meet (at the old bridge).'), ['we', 'meet', 'at', 'the', 'old', 'bridge']);
    expect(normalizer.words('caf\u0065\u0301 CAFÉ &#39;hello&#39; &#xD800;'), ['café', 'café', 'hello']);
  });

  test('index sorts chronologically but retains source ordinals, text and immutable postings', () {
    final original = document(['Later <i>lantern</i>', 'Earlier bridge']);
    final reversed = ParsedSubtitles(original.encoding, original.cues.reversed.toList());
    final index = SubtitleIndex(reversed);
    expect(index.words.map((word) => word.text), ['later', 'lantern', 'earlier', 'bridge']);
    expect(index.words.map((word) => word.cueOrdinal), [0, 0, 1, 1]);
    expect(reversed.cues.first.ordinal, 1);
    expect(original.cues.first.text, 'Later <i>lantern</i>');
    expect(() => index.words.clear(), throwsUnsupportedError);
    expect(() => index.positionsOf('lantern').add(5), throwsUnsupportedError);
    expect(() => SubtitleIndex(original, maximumWords: 2), throwsFormatException);
    expect(index.toString(), isNot(contains('lantern')));
  });

  test('spelled and abbreviated titles match exactly without changing source text', () {
    const source = 'Mister Brown carried the silver lantern to Doctor Green';
    final original = document([source]);
    final result = matcher.find('Mr. Brown carried the silver lantern to Dr. Green', SubtitleIndex(original));
    expect(result.status, TranscriptMatchStatus.matched);
    expect(result.passage!.similarity, 1);
    expect(result.passage!.words.every((word) => word.exact), isTrue);
    expect(original.cues.single.text, source);
    expect(normalizer.words('MR. Dr. mister doctor'), ['mister', 'doctor', 'mister', 'doctor']);
    expect(normalizer.words('Ms. Mrs. drive doctorate misterious'), ['ms', 'mrs', 'drive', 'doctorate', 'misterious']);
  });

  test('identifies a passage across cues without inventing a timing anchor', () {
    final index = SubtitleIndex(
      document([
        'Unrelated opening remarks',
        'Please bring the silver lantern',
        'across the wooden bridge tonight',
        'Closing words',
      ]),
    );
    final result = matcher.find(dialogue, index);
    expect(result.status, TranscriptMatchStatus.matched);
    expect(result.passage!.similarity, 1);
    expect(result.passage!.words, hasLength(10));
    expect(result.passage!.words.map((pair) => index.words[pair.subtitleWord].cueOrdinal).toSet(), {1, 2});
  });

  test('tolerates one ASR spelling error and one omitted word', () {
    final result = matcher.find(
      'Please bring silver lantarn across the wooden bridge tonight',
      SubtitleIndex(document([dialogue])),
    );
    expect(result.status, TranscriptMatchStatus.matched);
    expect(result.passage!.words.where((pair) => !pair.exact), hasLength(1));
    expect(result.passage!.similarity, lessThan(1));
  });

  test('rejects repeated passages both adjacent and far apart', () {
    for (final middle in ['', List.filled(80, 'irrelevant filler').join(' ')]) {
      final result = matcher.find(dialogue, SubtitleIndex(document([dialogue, middle, dialogue])));
      expect(result.status, TranscriptMatchStatus.ambiguous);
      expect(result.passage, isNull);
    }
  });

  test('rejects short, common-only, music and incompatible dialogue', () {
    final index = SubtitleIndex(document([dialogue, 'I am here and you are there', 'Thanks for watching']));
    for (final transcript in [
      'silver lantern',
      'I am here and you are there',
      '♪ $dialogue ♪',
      'Thanks for watching',
    ]) {
      expect(matcher.find(transcript, index).status, TranscriptMatchStatus.insufficientDialogue);
    }
    expect(
      matcher.find('Nobody remembers the purple spaceship landing beyond mountains', index).status,
      TranscriptMatchStatus.noCandidate,
    );
    expect(matcher.find('x' * 32769, index).status, TranscriptMatchStatus.insufficientDialogue);
  });

  test('candidate saturation refuses a lock instead of silently dropping competitors', () {
    final index = SubtitleIndex(document(List.filled(100, dialogue)));
    final result = matcher.find(dialogue, index);
    expect(result.status, TranscriptMatchStatus.ambiguous);
    expect(result.candidateLimitReached, isTrue);
  });

  test('margin considers a competing passage below the acceptance threshold', () {
    final index = SubtitleIndex(
      document([
        'Please bring the silver lantern across the wooden bridge tomorrow',
        List.filled(80, 'intermission').join(' '),
        'Please bring the orange lantern slowly across the stone bridge tonight',
      ]),
    );
    final result = const TranscriptMatcher(minimumMargin: 0.25).find(dialogue, index);
    expect(result.status, TranscriptMatchStatus.ambiguous);
    expect(result.runnerUpSimilarity, closeTo(0.7, 0.001));
  });

  test('caller can widen a failed local search to a global search', () {
    final index = SubtitleIndex(document([List.filled(80, 'opening').join(' '), dialogue]));
    expect(
      matcher.find(dialogue, index, expectedSubtitleTime: Duration.zero, radius: const Duration(seconds: 1)).status,
      TranscriptMatchStatus.noCandidate,
    );
    expect(matcher.find(dialogue, index).status, TranscriptMatchStatus.matched);
  });
}
