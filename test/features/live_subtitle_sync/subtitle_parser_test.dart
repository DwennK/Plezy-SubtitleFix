import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

String cue(String text, {String timing = '00:00:01,125 --> 00:00:03,500', String id = '1'}) => '$id\n$timing\n$text\n';

Matcher fails(SubtitleParseFailure failure) =>
    throwsA(isA<SubtitleParseException>().having((error) => error.reason, 'reason', failure));

void main() {
  const parser = SubtitleParser();

  test('preserves source order, duplicate IDs, overlaps, styles and positioning', () {
    final parsed = parser.parse(
      bytes(
        '\n${cue('<i> Hello </i>\nSecond line', timing: '00:00:02,000 --> 00:00:04,000 X1:20 X2:80')}'
        '\n\n${cue('Earlier overlapping cue', timing: '00:00:01.125 --> 00:00:03.500')}',
      ),
    );
    expect(parsed.cues.map((item) => item.ordinal), [0, 1]);
    expect(parsed.cues.map((item) => item.sourceId), ['1', '1']);
    expect(parsed.cues.first.text, '<i> Hello </i>\nSecond line');
    expect(parsed.cues.first.timingSuffix, ' X1:20 X2:80');
    expect(parsed.cues[1].start, const Duration(milliseconds: 1125));
    expect(parsed.cues[1].end, const Duration(milliseconds: 3500));
    expect(() => parsed.cues.clear(), throwsUnsupportedError);
    expect(parsed.toString(), isNot(contains('Earlier')));
    expect(parsed.cues.first.toString(), isNot(contains('Hello')));
  });

  test('accepts BOM, CRLF, CR, optional numeric IDs and whitespace separators', () {
    final parsed = parser.parse(
      bytes(
        '\ufeff${cue('One').replaceAll('\n', '\r\n')}\r\n \t\r\n'
        '00:00:05,000 --> 00:00:06,000\rTwo\r',
      ),
    );
    expect(parsed.encoding, SubtitleEncoding.utf8);
    expect(parsed.cues.map((item) => item.text), ['One', 'Two']);
    expect(parsed.cues[1].sourceId, isNull);
  });

  test('decodes UTF16 both endiannesses including valid surrogate pairs', () {
    final source = cue('English dialogue 🎵');
    for (final endian in [Endian.little, Endian.big]) {
      final data = ByteData((source.codeUnits.length + 1) * 2)..setUint16(0, 0xfeff, endian);
      for (var i = 0; i < source.codeUnits.length; i++) {
        data.setUint16((i + 1) * 2, source.codeUnits[i], endian);
      }
      final parsed = parser.parse(data.buffer.asUint8List());
      expect(parsed.cues.single.text, 'English dialogue 🎵');
      expect(
        parsed.encoding,
        endian == Endian.little ? SubtitleEncoding.utf16LittleEndian : SubtitleEncoding.utf16BigEndian,
      );
    }
  });

  test('identifies legacy Windows1252 instead of substituting replacement characters', () {
    final input = Uint8List.fromList([
      ...ascii.encode('1\n00:00:01,000 --> 00:00:02,000\nIt'),
      0x92,
      ...ascii.encode('s fine'),
    ]);
    final parsed = parser.parse(input);
    expect(parsed.encoding, SubtitleEncoding.windows1252);
    expect(parsed.cues.single.text, 'It’s fine');
  });

  test('rejects corrupt explicitly marked encodings and undefined ANSI bytes', () {
    for (final input in [
      [0xef, 0xbb, 0xbf, 0xff],
      [0xff, 0xfe, 0x01],
      [0xff, 0xfe, 0, 0xd8],
      [0xfe, 0xff, 0xdc, 0],
      [0xff, 0xfe, 0, 0xd8, 0x41, 0],
      [...bytes(cue('Text')), 0x81],
      [...bytes(cue('Text')), 0],
    ]) {
      expect(() => parser.parse(Uint8List.fromList(input)), fails(SubtitleParseFailure.invalidEncoding));
    }
  });

  test('refuses damaged middle cues rather than returning a plausible partial file', () {
    for (final bad in [
      cue('Backwards', timing: '00:00:03,000 --> 00:00:01,000'),
      cue('Zero', timing: '00:00:01,000 --> 00:00:01,000'),
      cue('Invalid minutes', timing: '00:65:01,000 --> 00:65:02,000'),
      cue('Invalid seconds', timing: '00:01:70,000 --> 00:01:80,000'),
      cue('Invalid milliseconds', timing: '00:00:01,1 --> 00:00:02,1'),
      '2\n00:00:05,000 --> 00:00:06,000\n',
      'WEBVTT\n',
      '${cue('Missing blank separator')}${cue('Another cue')}',
    ]) {
      expect(() => parser.parse(bytes('${cue('Good')}\n$bad\n${cue('Last')}')), fails(SubtitleParseFailure.malformed));
    }
  });

  test('bounds input and cue count and rejects empty documents', () {
    expect(() => const SubtitleParser(maximumBytes: 8).parse(bytes(cue('Text'))), fails(SubtitleParseFailure.tooLarge));
    expect(
      () => const SubtitleParser(maximumCues: 1).parse(bytes('${cue('One')}\n${cue('Two')}')),
      fails(SubtitleParseFailure.tooManyCues),
    );
    expect(() => parser.parse(bytes('\n \t\r\n')), fails(SubtitleParseFailure.empty));
  });

  final corpus = File('build/livesync/corpus-source/sintel_en.srt');
  test('reads all authored cues from the hash-pinned real Sintel fixture', () {
    final source = corpus.readAsBytesSync();
    expect(
      crypto.sha256.convert(source).toString(),
      '4ed7e1f1bc5ff69fe33606960e4c048ba6766237bf33b132fef76e1a92cb64b2',
    );
    final parsed = parser.parse(source);
    expect(parsed.cues, hasLength(26));
    expect(parsed.cues.every((item) => item.end > item.start), isTrue);
  }, skip: !corpus.existsSync() ? 'Run scripts/livesync/prepare_corpus.py to prepare this corpus proof' : false);
}
