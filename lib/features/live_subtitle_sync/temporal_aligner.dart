import 'dart:math' as math;

import 'native_bindings.dart';
import 'subtitle_index.dart';
import 'text_normalization.dart';
import 'transcript_matcher.dart';

class SubtitleAnchor {
  const SubtitleAnchor(this.cue, this.subtitleTime, this.mediaTime, this.uncertainty, this.phrase);
  final int cue;
  final double subtitleTime;
  final double mediaTime;
  final double uncertainty;

  /// Search-only phrase used transiently to prevent repeated evidence counting.
  final String phrase;
  double get offset => mediaTime - subtitleTime;
}

class _TimedWord {
  const _TimedWord(this.text, this.start, this.end, this.score, this.valid, this.speechUnsupported);
  final String text;
  final double start;
  final double end;
  final double score;
  final bool valid;
  final bool speechUnsupported;
}

/// Convert token pieces into words without assigning uniform cue word timing.
/// Initial uncertainty is conservative and heuristic; real-corpus calibration
/// must establish accuracy before treating these as precise timing evidence.
class TemporalAligner {
  const TemporalAligner();

  /// Short captions can borrow consecutive dialogue from the next caption.
  /// Choose disjoint evidence from the full SRT, before seeing recognition,
  /// so overlapping windows cannot count the same words as independent proof.
  /// Reserve existing long-cue evidence first, including its five-word retry.
  Set<int> _shortCueBeginnings(SubtitleIndex index) {
    final starts = <int>[
      for (var i = 0; i < index.words.length; i++)
        if (index.words[i].wordInCue == 0) i,
      index.words.length,
    ];
    final reserved = <int>{};
    for (var i = 0; i + 1 < starts.length; i++) {
      final count = starts[i + 1] - starts[i];
      if (count >= 3) {
        reserved.addAll(List.generate(math.min(5, count), (j) => starts[i] + j));
      }
    }
    final accepted = <int>{};
    for (var i = 0; i + 1 < starts.length; i++) {
      final first = starts[i];
      if (starts[i + 1] - first >= 3 || first + 3 > index.words.length) continue;
      final span = index.words[first + 2].cueStart - index.words[first].cueStart;
      if (span.isNegative || span > const Duration(seconds: 5)) continue;
      final evidence = List.generate(3, (j) => first + j);
      if (evidence.any(reserved.contains)) continue;
      accepted.add(first);
      reserved.addAll(evidence);
    }
    return accepted;
  }

  // Punctuation has no spoken onset. Keep every lexical subword (including
  // combining marks and the normalizer's spoken "and" for '&') under the
  // existing confidence/timestamp gates; discard only nonlexical pieces.
  static final _lexicalPiece = RegExp(r'[\p{L}\p{M}\p{N}&]', unicode: true);

  List<SubtitleAnchor> anchors(
    NativeTranscript transcript,
    SubtitleIndex index,
    PassageMatch passage, {
    Map<String, int>? rejectionCounts,
  }) {
    void rejected(String reason) {
      if (rejectionCounts != null) rejectionCounts[reason] = (rejectionCounts[reason] ?? 0) + 1;
    }

    final words = <_TimedWord>[];
    const normalizer = DialogueNormalizer();
    for (final segment in transcript.segments) {
      final text = segment.tokens.map((token) => token.text).join();
      final expectedWords = normalizer.words(segment.text);
      // A multiword annotation must be normalized as a whole: splitting
      // "[heavy breathing]" first would invent two spoken words and discard
      // every neighboring anchor. Require agreement with the token text too,
      // so an ignored segment cannot hide inconsistent lexical content.
      if (expectedWords.isEmpty && normalizer.words(text).isEmpty) continue;
      final starts = <int>[];
      var offset = 0;
      for (final token in segment.tokens) {
        starts.add(offset);
        offset += token.text.length;
      }
      final segmentWords = <_TimedWord>[];
      for (final span in RegExp(r'\S+').allMatches(text)) {
        final contributors = <NativeTranscriptToken>[];
        for (var i = 0; i < segment.tokens.length; i++) {
          if (starts[i] < span.end &&
              starts[i] + segment.tokens[i].text.length > span.start &&
              _lexicalPiece.hasMatch(segment.tokens[i].text)) {
            contributors.add(segment.tokens[i]);
          }
        }
        if (contributors.isEmpty) continue;
        final valid = contributors.every((token) => token.hasTimestamp && token.score >= 0.35);
        final start = contributors.map((token) => token.start).reduce(math.min);
        final end = contributors.map((token) => token.end).reduce(math.max);
        final score = contributors.map((token) => token.score).reduce(math.min);
        final speechUnsupported = contributors.any(
          (token) => token.start == start && token.speechSupport == NativeSpeechSupport.unsupported,
        );
        for (final word in normalizer.words(span[0]!)) {
          segmentWords.add(_TimedWord(word, start, end, score, valid && end > start, speechUnsupported));
        }
      }
      // Normalization can remove entire sound/music lines. Do not use an index
      // if independently normalizing the token spans changed word correspondence.
      if (segmentWords.map((word) => word.text).join(' ') != expectedWords.join(' ')) {
        rejected('normalizationMismatch');
        return [];
      }
      words.addAll(segmentWords);
    }
    final pairs = {for (final pair in passage.words) pair.subtitleWord: pair};
    if (rejectionCounts != null) {
      final touched = passage.words.map((pair) => index.words[pair.subtitleWord].cueOrdinal).toSet();
      final beginnings = passage.words
          .where((pair) => index.words[pair.subtitleWord].wordInCue == 0)
          .map((pair) => index.words[pair.subtitleWord].cueOrdinal)
          .toSet();
      for (final _ in touched.difference(beginnings)) {
        rejected('cueBeginningAbsent');
      }
    }
    final result = <SubtitleAnchor>[];
    final shortCueBeginnings = _shortCueBeginnings(index);
    for (final pair in passage.words) {
      final source = index.words[pair.subtitleWord];
      if (source.wordInCue != 0) continue;
      if (!pair.exact || pair.transcriptWord >= words.length) {
        rejected('cueBeginningNotMatched');
        continue;
      }
      final beginning = words[pair.transcriptWord];
      if (!beginning.valid) {
        rejected(beginning.score < 0.35 ? 'beginningLowConfidence' : 'beginningInvalidTimestamp');
        continue;
      }
      if (beginning.start < transcript.windowStart + 0.1 || beginning.end > transcript.windowEnd) {
        rejected('beginningAtWindowEdge');
        continue;
      }
      if (beginning.end - beginning.start > 2) {
        rejected('beginningTooWide');
        continue;
      }
      final matched = <String>[];
      String? matchFailure(int i) {
        final next = pairs[pair.subtitleWord + i];
        if (next == null ||
            !next.exact ||
            next.transcriptWord != pair.transcriptWord + i ||
            next.transcriptWord >= words.length ||
            (index.words[next.subtitleWord].cueOrdinal != source.cueOrdinal &&
                !shortCueBeginnings.contains(pair.subtitleWord))) {
          return 'phraseNotMatched';
        }
        if (!words[next.transcriptWord].valid) {
          return words[next.transcriptWord].score < 0.35 ? 'phraseLowConfidence' : 'phraseInvalidTimestamp';
        }
        return null;
      }

      String? failure;
      for (var i = 0; i < 3; i++) {
        failure = matchFailure(i);
        if (failure != null) break;
        matched.add(words[pair.transcriptWord + i].text);
      }
      if (matched.length < 3) {
        // A single interior substitution must not discard an accurately timed
        // cue beginning. Require four exact words at unchanged positions,
        // two on each side, plus valid monotonic times throughout. Insertions,
        // deletions, a missing first word or a repeated beginning do not qualify.
        const flanks = [0, 1, 3, 4];
        final canCheck =
            !shortCueBeginnings.contains(pair.subtitleWord) && flanks.every((i) => matchFailure(i) == null);
        final local = canCheck ? words.sublist(pair.transcriptWord, pair.transcriptWord + 5) : <_TimedWord>[];
        final validSubstitution =
            local.length == 5 &&
            local[2].text != beginning.text &&
            local.every((word) => word.valid && word.start >= beginning.start && word.end <= transcript.windowEnd) &&
            local.last.start - beginning.start <= 5 &&
            List.generate(4, (i) => local[i + 1].start >= local[i].start).every((value) => value);
        if (!validSubstitution) {
          rejected(failure ?? 'phraseNotMatched');
          continue;
        }
      }
      if (shortCueBeginnings.contains(pair.subtitleWord)) {
        final context = words.sublist(pair.transcriptWord, pair.transcriptWord + 3);
        if (context.last.start - beginning.start > 5 ||
            context.any((word) => word.start < beginning.start || word.end > transcript.windowEnd) ||
            context[1].start < context[0].start ||
            context[2].start < context[1].start) {
          rejected('shortCueContextDiscontinuous');
          continue;
        }
      }
      // Retain recognized text; reject only its unsupported cue-start timing.
      // Never snap an anchor to a voice edge or alter the recognition gates.
      if (beginning.speechUnsupported) {
        rejected('beginningUnsupportedSpeech');
        continue;
      }
      result.add(
        SubtitleAnchor(
          source.cueOrdinal,
          source.cueStart.inMicroseconds / 1e6,
          beginning.start,
          math.max(0.35, (beginning.end - beginning.start) / 2),
          // Keep the same deduplication identity whether ASR recognized all
          // three initial words or the guarded five-word substitution case.
          index.words.sublist(pair.subtitleWord, pair.subtitleWord + 3).map((word) => word.text).join(' '),
        ),
      );
    }
    return result;
  }
}
