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
  const _TimedWord(this.text, this.start, this.end, this.score, this.valid);
  final String text;
  final double start;
  final double end;
  final double score;
  final bool valid;
}

/// Convert token pieces into words without assigning uniform cue word timing.
/// Initial uncertainty is conservative and heuristic; real-corpus calibration
/// must establish accuracy before treating these as precise timing evidence.
class TemporalAligner {
  const TemporalAligner();

  List<SubtitleAnchor> anchors(NativeTranscript transcript, SubtitleIndex index, PassageMatch passage) {
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
          segmentWords.add(_TimedWord(word, start, end, score, valid && end > start));
        }
      }
      // Normalization can remove entire sound/music lines. Do not use an index
      // if independently normalizing the token spans changed word correspondence.
      if (segmentWords.map((word) => word.text).join(' ') != normalizer.words(segment.text).join(' ')) return [];
      words.addAll(segmentWords);
    }
    final pairs = {for (final pair in passage.words) pair.subtitleWord: pair};
    final result = <SubtitleAnchor>[];
    for (final pair in passage.words) {
      final source = index.words[pair.subtitleWord];
      if (!pair.exact || source.wordInCue != 0 || pair.transcriptWord >= words.length) continue;
      final beginning = words[pair.transcriptWord];
      if (!beginning.valid ||
          beginning.start < transcript.windowStart + 0.1 ||
          beginning.end > transcript.windowEnd ||
          beginning.end - beginning.start > 2) {
        continue;
      }
      final matched = <String>[];
      for (var i = 0; i < 3; i++) {
        final next = pairs[pair.subtitleWord + i];
        if (next == null ||
            !next.exact ||
            next.transcriptWord != pair.transcriptWord + i ||
            next.transcriptWord >= words.length ||
            index.words[next.subtitleWord].cueOrdinal != source.cueOrdinal ||
            !words[next.transcriptWord].valid) {
          break;
        }
        matched.add(words[next.transcriptWord].text);
      }
      if (matched.length < 3) continue;
      result.add(
        SubtitleAnchor(
          source.cueOrdinal,
          source.cueStart.inMicroseconds / 1e6,
          beginning.start,
          math.max(0.35, (beginning.end - beginning.start) / 2),
          matched.join(' '),
        ),
      );
    }
    return result;
  }
}

/// Constant-offset acquisition. Large corrections require distinct cue starts
/// and distinct phrases, separated in the source timeline. Repeated windows do
/// not create confirmations. Later segment fitting consumes the same anchors.
class ConstantOffsetEstimator {
  final _anchors = <int, SubtitleAnchor>{};

  void clear() => _anchors.clear();

  double? add(List<SubtitleAnchor> anchors) {
    for (final anchor in anchors) {
      if (anchor.offset.isFinite && anchor.uncertainty <= 1 && anchor.offset.abs() <= 600) {
        _anchors[anchor.cue] = anchor;
      }
    }
    while (_anchors.length > 24) {
      _anchors.remove(_anchors.keys.first);
    }
    final available = _anchors.values.toList();
    final groups = <List<SubtitleAnchor>>[];
    for (final center in available) {
      final group = available.where((anchor) => (anchor.offset - center.offset).abs() <= 0.8).toList();
      if (group.length < 2 || group.map((anchor) => anchor.phrase).toSet().length < 2) continue;
      final times = group.map((anchor) => anchor.subtitleTime).toList()..sort();
      if (times.last - times.first < 3) continue;
      groups.add(group);
    }
    if (groups.isEmpty) return null;
    groups.sort((a, b) => b.length.compareTo(a.length));
    final best = groups.first;
    if (available.length > best.length * 1.5) return null;
    final offsets = best.map((anchor) => anchor.offset).toList()..sort();
    return offsets.length.isOdd
        ? offsets[offsets.length ~/ 2]
        : (offsets[offsets.length ~/ 2 - 1] + offsets[offsets.length ~/ 2]) / 2;
  }
}
