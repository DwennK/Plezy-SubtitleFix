import 'dart:convert';
import 'dart:typed_data';

enum SubtitleParseFailure { empty, tooLarge, invalidEncoding, malformed, tooManyCues }

class SubtitleParseException implements Exception {
  const SubtitleParseException(this.reason);

  final SubtitleParseFailure reason;

  @override
  String toString() => 'SubtitleParseException(${reason.name})';
}

enum SubtitleEncoding { utf8, utf16LittleEndian, utf16BigEndian, windows1252 }

/// Original text and positioning suffix are opaque renderer content. Matching
/// must use a separate normalized representation; never replace this text with
/// a transcript. Ordinals identify source blocks even with duplicate SRT IDs.
class SubtitleCue {
  const SubtitleCue({
    required this.ordinal,
    required this.sourceId,
    required this.start,
    required this.end,
    required this.text,
    required this.timingSuffix,
  });

  final int ordinal;
  final String? sourceId;
  final Duration start;
  final Duration end;
  final String text;
  final String timingSuffix;

  @override
  String toString() => 'SubtitleCue($ordinal, ${start.inMilliseconds}..${end.inMilliseconds} ms)';
}

class ParsedSubtitles {
  ParsedSubtitles(this.encoding, List<SubtitleCue> cues) : cues = List.unmodifiable(cues);

  final SubtitleEncoding encoding;

  /// Original file order, including overlapping or out-of-order cues.
  final List<SubtitleCue> cues;

  @override
  String toString() => 'ParsedSubtitles(${encoding.name}, ${cues.length} cues)';
}

/// Complete-file parsing. Rejects a damaged cue instead of silently building a
/// partial timeline that could align unrelated dialogue. Run outside the UI
/// isolate when loading a document. No filesystem/network access or logging.
class SubtitleParser {
  const SubtitleParser({this.maximumBytes = 4 * 1024 * 1024, this.maximumCues = 50000});

  final int maximumBytes;
  final int maximumCues;

  static final _timing = RegExp(
    r'^\s*(\d{1,6}):([0-5]\d):([0-5]\d)[,.](\d{3})\s*-->\s*'
    r'(\d{1,6}):([0-5]\d):([0-5]\d)[,.](\d{3})([ \t].*)?$',
  );
  static final _id = RegExp(r'^\d+$');
  static final _blank = RegExp(r'\n[ \t]*\n');

  ParsedSubtitles parse(Uint8List bytes) {
    if (bytes.length > maximumBytes || maximumBytes <= 0) {
      throw const SubtitleParseException(SubtitleParseFailure.tooLarge);
    }
    final (decoded, encoding) = _decode(bytes);
    if (decoded.contains('\u0000')) {
      throw const SubtitleParseException(SubtitleParseFailure.invalidEncoding);
    }
    final source = decoded.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (source.trim().isEmpty) throw const SubtitleParseException(SubtitleParseFailure.empty);
    final cues = <SubtitleCue>[];
    for (final block in source.split(_blank)) {
      if (block.trim().isEmpty) continue;
      if (cues.length >= maximumCues) throw const SubtitleParseException(SubtitleParseFailure.tooManyCues);
      final lines = block.split('\n');
      while (lines.isNotEmpty && lines.first.trim().isEmpty) {
        lines.removeAt(0);
      }
      while (lines.isNotEmpty && lines.last.trim().isEmpty) {
        lines.removeLast();
      }
      String? sourceId;
      var timingLine = 0;
      if (lines.isNotEmpty && _id.hasMatch(lines.first.trim())) {
        sourceId = lines.first.trim();
        timingLine = 1;
      }
      if (lines.length <= timingLine + 1) throw const SubtitleParseException(SubtitleParseFailure.malformed);
      final timing = _timing.firstMatch(lines[timingLine]);
      if (timing == null) throw const SubtitleParseException(SubtitleParseFailure.malformed);
      final start = _time(timing, 1);
      final end = _time(timing, 5);
      if (end <= start) throw const SubtitleParseException(SubtitleParseFailure.malformed);
      final text = lines.skip(timingLine + 1).join('\n');
      if (text.trim().isEmpty || lines.skip(timingLine + 1).any((line) => _timing.hasMatch(line))) {
        throw const SubtitleParseException(SubtitleParseFailure.malformed);
      }
      cues.add(
        SubtitleCue(
          ordinal: cues.length,
          sourceId: sourceId,
          start: start,
          end: end,
          text: text,
          timingSuffix: timing.group(9) ?? '',
        ),
      );
    }
    if (cues.isEmpty) throw const SubtitleParseException(SubtitleParseFailure.empty);
    return ParsedSubtitles(encoding, cues);
  }

  static Duration _time(RegExpMatch match, int offset) => Duration(
    hours: int.parse(match.group(offset)!),
    minutes: int.parse(match.group(offset + 1)!),
    seconds: int.parse(match.group(offset + 2)!),
    milliseconds: int.parse(match.group(offset + 3)!),
  );

  static (String, SubtitleEncoding) _decode(Uint8List bytes) {
    if (bytes.length >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      if (bytes.length.isOdd) throw const SubtitleParseException(SubtitleParseFailure.invalidEncoding);
      final little = bytes[0] == 0xff;
      final data = ByteData.sublistView(bytes, 2);
      final units = <int>[];
      for (var offset = 0; offset < data.lengthInBytes; offset += 2) {
        units.add(data.getUint16(offset, little ? Endian.little : Endian.big));
      }
      for (var i = 0; i < units.length; i++) {
        if (units[i] >= 0xd800 && units[i] <= 0xdbff) {
          if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
            throw const SubtitleParseException(SubtitleParseFailure.invalidEncoding);
          }
        } else if (units[i] >= 0xdc00 && units[i] <= 0xdfff) {
          throw const SubtitleParseException(SubtitleParseFailure.invalidEncoding);
        }
      }
      return (
        String.fromCharCodes(units),
        little ? SubtitleEncoding.utf16LittleEndian : SubtitleEncoding.utf16BigEndian,
      );
    }
    final bom = bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;
    try {
      return (utf8.decode(bom ? Uint8List.sublistView(bytes, 3) : bytes), SubtitleEncoding.utf8);
    } on FormatException {
      // An explicit UTF-8 BOM must not silently turn a corrupt file into ANSI.
      if (bom) throw const SubtitleParseException(SubtitleParseFailure.invalidEncoding);
      // Legacy English SRTs commonly use Windows-1252. Undefined control codes
      // are rejected; the chosen fallback is exposed to callers, not hidden.
      const extended = <int>[
        0x20ac,
        0,
        0x201a,
        0x0192,
        0x201e,
        0x2026,
        0x2020,
        0x2021,
        0x02c6,
        0x2030,
        0x0160,
        0x2039,
        0x0152,
        0,
        0x017d,
        0,
        0,
        0x2018,
        0x2019,
        0x201c,
        0x201d,
        0x2022,
        0x2013,
        0x2014,
        0x02dc,
        0x2122,
        0x0161,
        0x203a,
        0x0153,
        0,
        0x017e,
        0x0178,
      ];
      final codes = <int>[];
      for (final byte in bytes) {
        final code = byte >= 0x80 && byte <= 0x9f ? extended[byte - 0x80] : byte;
        if (code == 0) throw const SubtitleParseException(SubtitleParseFailure.invalidEncoding);
        codes.add(code);
      }
      return (String.fromCharCodes(codes), SubtitleEncoding.windows1252);
    }
  }
}
