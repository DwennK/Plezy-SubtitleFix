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
    for (final cue in chronological) {
      final tokens = normalizer.words(cue.text);
      if (indexed.length + tokens.length > maximumWords) throw const FormatException('Subtitle index word limit');
      for (var i = 0; i < tokens.length; i++) {
        (positions[tokens[i]] ??= []).add(indexed.length);
        indexed.add(IndexedSubtitleWord(tokens[i], cue.ordinal, i, cue.start));
      }
    }
    words = List.unmodifiable(indexed);
    _positions = Map.unmodifiable(positions.map((word, indexes) => MapEntry(word, List<int>.unmodifiable(indexes))));
  }

  late final List<IndexedSubtitleWord> words;
  late final Map<String, List<int>> _positions;

  List<int> positionsOf(String word) => _positions[word] ?? const [];

  @override
  String toString() => 'SubtitleIndex(${words.length} words)';
}
