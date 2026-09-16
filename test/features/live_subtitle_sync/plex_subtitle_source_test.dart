import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/features/live_subtitle_sync/plex_subtitle_source.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_source.dart';
import 'package:plezy/utils/media_server_http_client.dart';

const _srt = '1\n00:00:11,924 --> 00:00:14,058\nFixture dialogue.\n';

http.Response metadata({int streamId = 42, String codec = 'srt'}) => http.Response(
  jsonEncode({
    'MediaContainer': {
      'Metadata': [
        {
          'ratingKey': 'episode',
          'Media': [
            {
              'Part': [
                {
                  'Stream': [
                    {'streamType': 1, 'codec': 'h264', 'decision': 'copy'},
                    {'streamType': 2, 'codec': 'eac3', 'decision': 'copy', 'selected': true},
                    {'decision': 'copy', 'streamType': 3, 'id': streamId, 'codec': codec, 'selected': true},
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
  }),
  200,
);

MockClient mockPlex(
  Future<http.Response> Function(http.Request) handler, {
  String videoDecision = 'copy',
  void Function(http.Request)? onStop,
}) => MockClient((request) async {
  if (request.url.path.endsWith('/decision')) {
    expect(request.url.queryParameters['directStreamAudio'], '1');
    final body = jsonDecode(metadata().body);
    body['MediaContainer']['Metadata'][0]['Media'][0]['Part'][0]['Stream'][0]['decision'] = videoDecision;
    body['MediaContainer']['Metadata'][0]['Media'][0]['Part'][0]['Stream'][2]['id'] = '42';
    return http.Response(jsonEncode(body), 200);
  }
  if (request.url.path.endsWith('/stop')) {
    onStop?.call(request);
    return http.Response('', 200);
  }
  return handler(request);
});

PlexSubtitleSource source({Duration timeout = const Duration(seconds: 1)}) => PlexSubtitleSource(
  baseUrl: 'https://server.invalid',
  headers: {'X-Plex-Token': 'private', 'X-Plex-Client-Profile-Name': 'Generic'},
  itemId: 'episode',
  mediaIndex: 0,
  partIndex: 0,
  timeout: timeout,
);

void main() {
  test('loads only complete selected subtitle text and reuses it within the source', () async {
    var metadataReads = 0;
    var subtitleReads = 0;
    final client = mockPlex((request) async {
      expect(request.method, 'GET');
      expect(request.headers['X-Plex-Token'], 'private');
      expect(request.url.toString(), isNot(contains('private')));
      if (request.url.path == '/library/metadata/episode') {
        metadataReads++;
        return metadata();
      }
      subtitleReads++;
      expect(request.url.path, '/video/:/transcode/universal/subtitles');
      expect(request.url.queryParameters['path'], '/library/metadata/episode');
      expect(request.url.queryParameters['protocol'], isNull);
      expect(request.url.queryParameters['session'], isNotEmpty);
      expect(request.headers['X-Plex-Client-Profile-Name'], isNull);
      expect(request.headers['X-Plex-Platform'], 'Chrome');
      expect(request.headers['X-Plex-Client-Identifier'], 'plezy-livesync-${request.url.queryParameters['session']}');
      expect(request.followRedirects, isFalse);
      // The real server labels its SRT body text/vtt; content must still parse.
      return http.Response(_srt, 200, headers: {'content-type': 'text/vtt;charset=utf-8'});
    });
    final adapter = source();
    final document = await adapter.load(42, client, AbortController());
    expect(const SubtitleParser().parse(document.bytes).cues.single.start.inMilliseconds, 11924);
    expect(await adapter.load(42, client, AbortController()), same(document));
    expect(metadataReads, 3);
    expect(subtitleReads, 1);
  });

  test('refuses a different selected track without requesting or selecting subtitles', () async {
    var requests = 0;
    final client = mockPlex((request) async {
      requests++;
      expect(request.url.path, '/library/metadata/episode');
      return metadata(streamId: 99);
    });
    await expectLater(
      source().load(42, client, AbortController()),
      throwsA(isA<SubtitleSourceException>().having((e) => e.reason, 'reason', SubtitleSourceFailure.unsupported)),
    );
    expect(requests, 1);
  });

  test('rejects a selection changed while the full document was loading', () async {
    var metadataReads = 0;
    final client = mockPlex((request) async {
      if (request.url.path.startsWith('/library/metadata/')) {
        return metadata(streamId: ++metadataReads == 1 ? 42 : 99);
      }
      return http.Response(_srt, 200, headers: {'content-type': 'text/srt'});
    });
    await expectLater(source().load(42, client, AbortController()), throwsA(isA<SubtitleSourceException>()));
  });

  for (final contentType in ['video/mp2t', 'audio/aac', 'application/vnd.apple.mpegurl']) {
    test('rejects $contentType instead of treating it as subtitle text', () async {
      final client = mockPlex(
        (request) async => request.url.path.startsWith('/library/metadata/')
            ? metadata()
            : http.Response('not subtitle text', 200, headers: {'content-type': contentType}),
      );
      await expectLater(source().load(42, client, AbortController()), throwsA(isA<SubtitleSourceException>()));
    });
  }

  test('refuses audio/video decoding before starting extraction and closes only its session', () async {
    var subtitleReads = 0;
    String? closed;
    final client = mockPlex(
      (request) async {
        if (request.url.path.startsWith('/library/metadata/')) return metadata();
        subtitleReads++;
        return http.Response(_srt, 200, headers: {'content-type': 'text/srt'});
      },
      videoDecision: 'transcode',
      onStop: (request) => closed = request.url.queryParameters['session'],
    );
    await expectLater(source().load(42, client, AbortController()), throwsA(isA<SubtitleSourceException>()));
    expect(subtitleReads, 0);
    expect(closed, matches(RegExp(r'^[0-9a-f-]{36}$')));
  });

  test('a cancelled read cannot return even a cached document', () async {
    final client = mockPlex(
      (request) async => request.url.path.startsWith('/library/metadata/')
          ? metadata()
          : http.Response(_srt, 200, headers: {'content-type': 'text/srt'}),
    );
    final adapter = source();
    await adapter.load(42, client, AbortController());
    final abort = AbortController()..abort();
    await expectLater(
      adapter.load(42, client, abort),
      throwsA(isA<SubtitleSourceException>().having((e) => e.reason, 'reason', SubtitleSourceFailure.cancelled)),
    );
  });
}
