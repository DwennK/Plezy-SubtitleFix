import 'dart:math' as math;
import 'dart:typed_data';

import 'subtitle_index.dart';
import 'text_normalization.dart';

enum TranscriptMatchStatus { matched, insufficientDialogue, noCandidate, ambiguous }

class WordCorrespondence {
  const WordCorrespondence(this.transcriptWord, this.subtitleWord, this.exact);

  final int transcriptWord;
  final int subtitleWord;
  final bool exact;
}

class PassageMatch {
  PassageMatch({required this.similarity, required List<WordCorrespondence> words}) : words = List.unmodifiable(words);

  /// Heuristic edit similarity, not a calibrated probability or timing score.
  final double similarity;
  final List<WordCorrespondence> words;

  int get firstSubtitleWord => words.first.subtitleWord;
  int get lastSubtitleWord => words.last.subtitleWord;
}

class TranscriptMatchResult {
  const TranscriptMatchResult(this.status, {this.passage, this.runnerUpSimilarity, this.candidateLimitReached = false});

  final TranscriptMatchStatus status;
  final PassageMatch? passage;
  final double? runnerUpSimilarity;
  final bool candidateLimitReached;
}

/// Passage identification only. A textual match does not establish a precise
/// audio/SRT anchor. Thresholds are initial conservative heuristics pending
/// calibration on the designated corpus partition. Call off the UI isolate.
class TranscriptMatcher {
  const TranscriptMatcher({
    this.minimumWords = 6,
    this.minimumContentWords = 3,
    this.minimumSimilarity = 0.78,
    this.minimumMargin = 0.12,
    this.maximumCandidateWindows = 64,
  });

  final int minimumWords;
  final int minimumContentWords;
  final double minimumSimilarity;
  final double minimumMargin;
  final int maximumCandidateWindows;

  static const _common = {
    'a',
    'an',
    'the',
    'i',
    'you',
    'he',
    'she',
    'it',
    'we',
    'they',
    'me',
    'him',
    'her',
    'us',
    'them',
    'my',
    'your',
    'his',
    'its',
    'our',
    'their',
    'is',
    'are',
    'was',
    'were',
    'be',
    'been',
    'am',
    'do',
    'does',
    'did',
    'have',
    'has',
    'had',
    'can',
    'could',
    'will',
    'would',
    'shall',
    'should',
    'not',
    'no',
    'yes',
    'and',
    'or',
    'but',
    'if',
    'as',
    'at',
    'by',
    'for',
    'from',
    'in',
    'of',
    'on',
    'to',
    'with',
    'that',
    'this',
    'there',
    'here',
    'what',
    'who',
    'how',
    'so',
    'just',
  };

  TranscriptMatchResult find(
    String transcript,
    SubtitleIndex index, {
    Duration? expectedSubtitleTime,
    Duration? radius,
  }) {
    if (transcript.length > 32768) return const TranscriptMatchResult(TranscriptMatchStatus.insufficientDialogue);
    final query = const DialogueNormalizer().words(transcript);
    if (query.length < minimumWords ||
        query.length > 128 ||
        query.where((word) => !_common.contains(word)).toSet().length < minimumContentWords) {
      return const TranscriptMatchResult(TranscriptMatchStatus.insufficientDialogue);
    }
    // Choose rare exact seeds, then allow edit errors in the surrounding span.
    // Saturation is an ambiguity, never permission to silently drop competitors.
    final seeds = query.toSet().where((word) => index.positionsOf(word).isNotEmpty).toList()
      ..sort((a, b) => index.positionsOf(a).length.compareTo(index.positionsOf(b).length));
    final starts = <int>{};
    var coveredQueryWords = 0;
    for (final seed in seeds) {
      coveredQueryWords += query.where((word) => word == seed).length;
      for (final position in index.positionsOf(seed)) {
        if (expectedSubtitleTime != null &&
            radius != null &&
            (index.words[position].cueStart - expectedSubtitleTime).abs() > radius) {
          continue;
        }
        for (var q = 0; q < query.length; q++) {
          if (query[q] != seed) continue;
          starts.add(math.max(0, position - q - 12));
          if (starts.length > maximumCandidateWindows) {
            return const TranscriptMatchResult(TranscriptMatchStatus.ambiguous, candidateLimitReached: true);
          }
        }
      }
      // Every accepted passage has at least 60% exact words. Seed more than
      // the remaining 40% so every such competitor must share a searched seed.
      if (coveredQueryWords > query.length * 0.4) break;
    }
    final candidates = <PassageMatch>[];
    for (final start in starts) {
      final end = math.min(index.words.length, start + query.length + 24);
      for (final candidate in _align(query, index, start, end)) {
        final duplicate = candidates.indexWhere((other) => _sameOccurrence(candidate, other));
        if (duplicate < 0) {
          candidates.add(candidate);
        } else if (candidate.similarity > candidates[duplicate].similarity) {
          candidates[duplicate] = candidate;
        }
        if (candidates.length > 32) {
          return const TranscriptMatchResult(TranscriptMatchStatus.ambiguous, candidateLimitReached: true);
        }
      }
    }
    candidates.sort((a, b) => b.similarity.compareTo(a.similarity));
    if (candidates.isEmpty) return const TranscriptMatchResult(TranscriptMatchStatus.noCandidate);
    final best = candidates.first;
    if (best.similarity < minimumSimilarity) {
      return const TranscriptMatchResult(TranscriptMatchStatus.noCandidate);
    }
    final runnerUp = candidates.length > 1 ? candidates[1].similarity : null;
    if (runnerUp != null && best.similarity - runnerUp < minimumMargin) {
      return TranscriptMatchResult(TranscriptMatchStatus.ambiguous, runnerUpSimilarity: runnerUp);
    }
    return TranscriptMatchResult(TranscriptMatchStatus.matched, passage: best, runnerUpSimilarity: runnerUp);
  }

  bool _sameOccurrence(PassageMatch a, PassageMatch b) {
    final overlap =
        math.min(a.lastSubtitleWord, b.lastSubtitleWord) - math.max(a.firstSubtitleWord, b.firstSubtitleWord) + 1;
    final shorter = math.min(
      a.lastSubtitleWord - a.firstSubtitleWord + 1,
      b.lastSubtitleWord - b.firstSubtitleWord + 1,
    );
    return overlap > 0 && overlap / shorter >= 0.6;
  }

  Iterable<PassageMatch> _align(List<String> query, SubtitleIndex index, int start, int end) sync* {
    final columns = end - start + 1;
    final costs = Float32List((query.length + 1) * columns);
    final direction = Uint8List(costs.length);
    for (var i = 1; i <= query.length; i++) {
      costs[i * columns] = i.toDouble();
      direction[i * columns] = 2;
      for (var j = 1; j < columns; j++) {
        final position = i * columns + j;
        final diagonal = costs[position - columns - 1] + _wordCost(query[i - 1], index.words[start + j - 1].text);
        final up = costs[position - columns] + 1;
        final left = costs[position - 1] + 1;
        costs[position] = math.min(diagonal, math.min(up, left));
        direction[position] = diagonal <= up && diagonal <= left ? 1 : (up <= left ? 2 : 3);
      }
    }
    for (var endpoint = 1; endpoint < columns; endpoint++) {
      final cost = costs[query.length * columns + endpoint];
      if (cost > query.length * (1 - minimumSimilarity + minimumMargin)) continue;
      var i = query.length;
      var j = endpoint;
      final pairs = <WordCorrespondence>[];
      while (i > 0) {
        final step = direction[i * columns + j];
        if (step == 1) {
          final wordCost = _wordCost(query[i - 1], index.words[start + j - 1].text);
          if (wordCost < 1) pairs.add(WordCorrespondence(i - 1, start + j - 1, wordCost == 0));
          i--;
          j--;
        } else if (step == 2 || j == 0) {
          i--;
        } else {
          j--;
        }
      }
      if (pairs.length < minimumWords ||
          pairs.length / query.length < 0.72 ||
          pairs.where((pair) => pair.exact).length / query.length < 0.6 ||
          pairs.map((pair) => query[pair.transcriptWord]).where((word) => !_common.contains(word)).toSet().length <
              minimumContentWords) {
        continue;
      }
      yield PassageMatch(similarity: 1 - cost / query.length, words: pairs.reversed.toList());
    }
  }

  static double _wordCost(String a, String b) {
    if (a == b) return 0;
    if (a.length < 5 || b.length < 5 || (a.length - b.length).abs() > 1) return 1;
    var i = 0;
    var j = 0;
    var edits = 0;
    while (i < a.length && j < b.length) {
      if (a.codeUnitAt(i) == b.codeUnitAt(j)) {
        i++;
        j++;
      } else {
        if (++edits > 1) return 1;
        if (a.length >= b.length) i++;
        if (b.length >= a.length) j++;
      }
    }
    edits += (a.length - i) + (b.length - j);
    return edits <= 1 ? 0.5 : 1;
  }
}
