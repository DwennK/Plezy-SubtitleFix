import 'subtitle_parser.dart';
import 'text_normalization.dart';

class IndexedSubtitleWord {
  const IndexedSubtitleWord(this.text, this.cueOrdinal, this.wordInCue, this.cueStart);

  final String text;
  final int cueOrdinal;
  final int wordInCue;
  final Duration cueStart;
}

/// Chronological search index; source cues/text remain unchanged. Build in the
/// analysis isolate. Limits are intentionally independent of the byte loader.
class SubtitleIndex {
  SubtitleIndex(
    ParsedSubtitles source, {
    int maximumWords = 150000,
    DialogueNormalizer normalizer = const DialogueNormalizer(),
  }) {
    final chronological = source.cues.toList()
      ..sort((a, b) {
        final order = a.start.compareTo(b.start);
        return order == 0 ? a.ordinal.compareTo(b.ordinal) : order;
      });
    final indexed = <IndexedSubtitleWord>[];
    final positions = <String, List<int>>{};
    final intervals = <(double, double)>[];
    for (final cue in chronological) {
      final tokens = normalizer.words(cue.text);
      if (tokens.isNotEmpty) {
        final start = cue.start.inMicroseconds / 1e6;
        final end = cue.end.inMicroseconds / 1e6;
        if (intervals.isNotEmpty && intervals.last.$2 >= start) {
          final previous = intervals.removeLast();
          intervals.add((previous.$1, previous.$2 > end ? previous.$2 : end));
        } else {
          intervals.add((start, end));
        }
      }
      if (indexed.length + tokens.length > maximumWords) throw const FormatException('Subtitle index word limit');
      for (var i = 0; i < tokens.length; i++) {
        (positions[tokens[i]] ??= []).add(indexed.length);
        indexed.add(IndexedSubtitleWord(tokens[i], cue.ordinal, i, cue.start));
      }
    }
    words = List.unmodifiable(indexed);
    _dialogueIntervals = List.unmodifiable(intervals);
    _positions = Map.unmodifiable(positions.map((word, indexes) => MapEntry(word, List<int>.unmodifiable(indexes))));
  }

  late final List<IndexedSubtitleWord> words;
  late final List<(double, double)> _dialogueIntervals;
  late final Map<String, List<int>> _positions;

  List<int> positionsOf(String word) => _positions[word] ?? const [];

  /// Union of text-cue durations, excluding normalized non-dialogue markers.
  /// Used only for a coarse VAD consistency check; caption edges are not exact
  /// voice onsets. Overlapping cues must not double the expected duration.
  double dialogueSecondsBetween(double start, double end) {
    if (!start.isFinite || !end.isFinite || end <= start) return 0;
    var low = 0;
    var high = _dialogueIntervals.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_dialogueIntervals[middle].$2 <= start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    var seconds = 0.0;
    for (var i = low; i < _dialogueIntervals.length && _dialogueIntervals[i].$1 < end; i++) {
      final interval = _dialogueIntervals[i];
      seconds += (interval.$2 < end ? interval.$2 : end) - (interval.$1 > start ? interval.$1 : start);
    }
    return seconds;
  }

  @override
  String toString() => 'SubtitleIndex(${words.length} words)';
}
