import 'package:unorm_dart/unorm_dart.dart';

/// Search-only normalization. The original SRT is retained separately for
/// rendering. Ambiguous contractions ('s, 'd) are not expanded into guesses.
class DialogueNormalizer {
  const DialogueNormalizer();

  static final _markup = RegExp(r'</?(?:i|b|u|s|font)(?:\s[^<>]{0,256})?>', caseSensitive: false);
  static final _ass = RegExp(r'\{\\[^{}]{0,256}\}');
  static final _square = RegExp(r'\[[^\[\]]{0,256}\]');
  static final _sounds = RegExp(
    r'\((?:music|sighs?|gasps?|laughs?|laughing|screams?|applause|inaudible|silence|coughs?|grunts?)[^()]{0,40}\)',
    caseSensitive: false,
  );
  static final _speaker = RegExp(r'^\s*-?\s*[A-Z][A-Z .\x27-]{1,30}:\s*');
  static final _words = RegExp(r"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:'[\p{L}]+)?", unicode: true);
  static final _entities = RegExp(r'&(?:amp|lt|gt|quot|apos|nbsp|#\d{1,7}|#x[0-9a-fA-F]{1,6});');

  List<String> words(String source) {
    var text = nfkc(source).replaceAll(RegExp('[‘’ʼ]'), "'");
    text = text
        .split('\n')
        .where((line) => !line.contains('♪') && !line.contains('♫'))
        .map((line) => line.replaceFirst(_speaker, ''))
        .join(' ');
    text = text.replaceAllMapped(_entities, (match) {
      final entity = match[0]!;
      const named = {'&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'", '&nbsp;': ' '};
      if (named.containsKey(entity)) return named[entity]!;
      final hex = entity.startsWith('&#x');
      final value = int.tryParse(entity.substring(hex ? 3 : 2, entity.length - 1), radix: hex ? 16 : 10);
      if (value == null || value <= 0 || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return ' ';
      return String.fromCharCode(value);
    });
    text = text.replaceAll(_markup, ' ').replaceAll(_ass, ' ').replaceAll(_square, ' ').replaceAll(_sounds, ' ');
    text = text.toLowerCase().replaceAll('&', ' and ');
    final result = <String>[];
    for (final match in _words.allMatches(text)) {
      final word = match[0]!;
      if (word == "can't" || word == 'cannot') {
        result.addAll(['can', 'not']);
      } else if (word == "won't") {
        result.addAll(['will', 'not']);
      } else if (word.endsWith("n't") && word.length > 3 && word != "ain't") {
        result.addAll([word.substring(0, word.length - 3), 'not']);
      } else {
        const suffixes = {"'re": 'are', "'ve": 'have', "'ll": 'will', "'m": 'am'};
        final suffix = suffixes.keys.where(word.endsWith).firstOrNull;
        if (suffix != null && word.length > suffix.length) {
          result.addAll([word.substring(0, word.length - suffix.length), suffixes[suffix]!]);
        } else {
          result.add(word);
        }
      }
    }
    return result;
  }
}
