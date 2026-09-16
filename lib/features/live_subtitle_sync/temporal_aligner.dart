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
  const _TimedWord(this.text, this.start, this.end, this.score, this.valid, this.timestampValid);
  final String text;
  final double start;
  final double end;
  final double score;
  final bool valid;
  final bool timestampValid;
}

/// Convert token pieces into words without assigning uniform cue word timing.
/// Initial uncertainty is conservative and heuristic; real-corpus calibration
/// must establish accuracy before treating these as precise timing evidence.
class TemporalAligner {
  const TemporalAligner({this.experimentalAcousticBeginnings = false});

  /// Development-only hypothesis; production keeps exact cue beginnings.
  final bool experimentalAcousticBeginnings;

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
          if (starts[i] < span.end && starts[i] + segment.tokens[i].text.length > span.start) {
            contributors.add(segment.tokens[i]);
          }
        }
        if (contributors.isEmpty) continue;
        final valid = contributors.every((token) => token.hasTimestamp && token.score >= 0.35);
        final start = contributors.map((token) => token.start).reduce(math.min);
        final end = contributors.map((token) => token.end).reduce(math.max);
        final score = contributors.map((token) => token.score).reduce(math.min);
        for (final word in normalizer.words(span[0]!)) {
          segmentWords.add(
            _TimedWord(
              word,
              start,
              end,
              score,
              valid && end > start,
              contributors.every((token) => token.hasTimestamp && token.start.isFinite && token.end.isFinite) &&
                  end > start,
            ),
          );
        }
      }
      // Normalization can remove entire sound/music lines. Do not use an index
      // if independently normalizing the token spans changed word correspondence.
      if (segmentWords.map((word) => word.text).join(' ') != normalizer.words(segment.text).join(' ')) {
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
            index.words[next.subtitleWord].cueOrdinal != source.cueOrdinal) {
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
        final canCheck = flanks.every((i) => matchFailure(i) == null);
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
    if (experimentalAcousticBeginnings) {
      final accepted = result.map((anchor) => anchor.cue).toSet();
      for (final pair in passage.words) {
        final source = index.words[pair.subtitleWord];
        if (source.wordInCue != 1 || accepted.contains(source.cueOrdinal)) continue;
        final recovered = _acousticBeginning(transcript, index, passage, words, pairs, pair);
        if (recovered == null) {
          rejected('acousticBeginningUnproven');
        } else {
          result.add(recovered);
          accepted.add(recovered.cue);
        }
      }
    }
    return result;
  }

  SubtitleAnchor? _acousticBeginning(
    NativeTranscript transcript,
    SubtitleIndex index,
    PassageMatch passage,
    List<_TimedWord> words,
    Map<int, WordCorrespondence> pairs,
    WordCorrespondence second,
  ) {
    final firstSource = second.subtitleWord - 1;
    final firstQuery = second.transcriptWord - 1;
    // Require a real preceding cue and exactly one unassigned ASR word between
    // its last word and five exact words in the new cue. A missing word, an
    // insertion, or a clipped start cannot be reconstructed from VAD alone.
    if (firstSource < 1 || firstQuery < 1 || firstQuery + 5 >= words.length) return null;
    final cue = index.words[firstSource];
    final left = pairs[firstSource - 1];
    if (left == null ||
        !left.exact ||
        left.transcriptWord != firstQuery - 1 ||
        index.words[firstSource - 1].cueOrdinal == cue.cueOrdinal) {
      return null;
    }
    final firstPair = pairs[firstSource];
    if (firstPair != null && (firstPair.exact || firstPair.transcriptWord != firstQuery)) return null;
    if (passage.words.any((pair) => pair.transcriptWord == firstQuery && pair.subtitleWord != firstSource)) return null;
    final preceding = words[firstQuery - 1];
    final beginning = words[firstQuery];
    if (!preceding.valid ||
        !beginning.timestampValid ||
        beginning.text == cue.text ||
        beginning.start < transcript.windowStart + 0.1 ||
        beginning.end > transcript.windowEnd ||
        beginning.end - beginning.start > 2 ||
        preceding.end > beginning.start) {
      return null;
    }
    var previousStart = beginning.start;
    for (var i = 1; i <= 5; i++) {
      final pair = pairs[firstSource + i];
      if (pair == null ||
          !pair.exact ||
          pair.transcriptWord != firstQuery + i ||
          index.words[pair.subtitleWord].cueOrdinal != cue.cueOrdinal) {
        return null;
      }
      final word = words[pair.transcriptWord];
      if (!word.valid ||
          word.start < previousStart ||
          word.end > transcript.windowEnd ||
          word.start - beginning.start > 5) {
        return null;
      }
      previousStart = word.start;
    }
    // Count every nearby activity start, including weak ones. Filtering weak
    // candidates first would turn ambiguous noise into a unique speech onset.
    final nearby = transcript.voiceOnsets
        .where((onset) => onset.start.isFinite && (onset.start - beginning.start).abs() <= 0.25)
        .toList();
    if (nearby.length != 1) return null;
    final onset = nearby.single;
    if (!onset.end.isFinite ||
        !onset.precedingQuietSeconds.isFinite ||
        !onset.activeSeconds.isFinite ||
        onset.start < transcript.windowStart + 0.1 ||
        onset.end > transcript.windowEnd ||
        onset.start < preceding.end ||
        onset.start >= words[firstQuery + 1].start ||
        onset.precedingQuietSeconds < 0.4 ||
        onset.activeSeconds < 0.3 ||
        onset.activeSeconds > onset.end - onset.start + 1e-6 ||
        onset.start - onset.precedingQuietSeconds < transcript.windowStart ||
        onset.end < beginning.end) {
      return null;
    }
    return SubtitleAnchor(
      cue.cueOrdinal,
      cue.cueStart.inMicroseconds / 1e6,
      onset.start,
      0.5,
      index.words.sublist(firstSource, firstSource + 3).map((word) => word.text).join(' '),
    );
  }
}
