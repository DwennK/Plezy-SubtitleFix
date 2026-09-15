import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_source.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/utils/media_server_http_client.dart';

const content = '1\n00:00:01,000 --> 00:00:02,000\nOriginal English dialogue.\n';

Matcher failure(SubtitleSourceFailure reason) =>
    isA<SubtitleSourceException>().having((e) => e.reason, 'reason', reason);

void main() {
  test('local sidecars preserve original bytes, support file URI and remain unchanged', () async {
    final directory = await Directory.systemTemp.createTemp('livesync-source-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/subtitle.srt');
    final original = utf8.encode(content);
    await file.writeAsBytes(original);
    final client = MockClient((_) => throw StateError('Local file must not use HTTP'));
    final loader = SubtitleSourceLoader(client: client);
    final first = await loader.load(SubtitleTrack.uri(file.path, codec: 'srt'));
    final second = await loader.load(SubtitleTrack.uri(file.uri.toString()));
    expect(first.bytes, original);
    expect(second.bytes, original);
    expect(first.contentHash, second.contentHash);
    expect(first.contentHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(() => first.bytes[0] = 0, throwsUnsupportedError);
    expect(await file.readAsBytes(), original);
    expect(first.toString(), isNot(contains('dialogue')));
    expect(first.toString(), isNot(contains(directory.path)));
  });

  test('real HTTP retrieves the whole SRT with the existing URL and auth headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = IOClient();
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    var requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.uri.path, '/Videos/item/source/Subtitles/2/Stream.srt');
      expect(request.uri.queryParameters['api_key'], 'fixture-token');
      expect(request.headers.value('Authorization'), 'Bearer fixture');
      request.response.write(content);
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/Videos/item/source/Subtitles/2/Stream.srt?api_key=fixture-token';
    final document = await SubtitleSourceLoader(
      client: client,
    ).load(SubtitleTrack.uri(url, codec: 'subrip'), headers: {'Authorization': 'Bearer fixture'});
    expect(utf8.decode(document.bytes), content);
    expect(requests, 1);
    expect(document.toString(), isNot(contains('fixture-token')));
    // The loader borrows the client; it must still be usable afterwards.
    final response = await client.get(Uri.parse(url), headers: {'Authorization': 'Bearer fixture'});
    expect(response.statusCode, 200);
  });

  test('unknown-length streaming data stops at the size bound and cancels the stream', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(onCancel: () => cancelled = true);
    final client = _StreamingClient((_) async => http.StreamedResponse(stream.stream, 200));
    final pending = SubtitleSourceLoader(
      client: client,
      maximumBytes: 8,
    ).load(SubtitleTrack.uri('https://example.invalid/subtitle.srt'));
    final assertion = expectLater(pending, throwsA(failure(SubtitleSourceFailure.tooLarge)));
    stream.add(Uint8List(4));
    stream.add(Uint8List(5));
    await assertion;
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('rejects an excessive advertised response before consuming its body', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(onCancel: () => cancelled = true);
    final client = _StreamingClient((_) async => http.StreamedResponse(stream.stream, 200, contentLength: 999));
    await expectLater(
      SubtitleSourceLoader(client: client, maximumBytes: 8).load(SubtitleTrack.uri('https://example.invalid/a.srt')),
      throwsA(failure(SubtitleSourceFailure.tooLarge)),
    );
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('cancels a real HTTP body that has stalled without another chunk', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = IOClient();
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    final started = Completer<void>();
    server.listen((request) async {
      request.response.write('1\n');
      await request.response.flush();
      started.complete();
    });
    final abort = AbortController();
    final pending = SubtitleSourceLoader(
      client: client,
    ).load(SubtitleTrack.uri('http://127.0.0.1:${server.port}/subtitle.srt'), abort: abort);
    final assertion = expectLater(pending, throwsA(failure(SubtitleSourceFailure.cancelled)));
    await started.future;
    abort.abort();
    await assertion.timeout(const Duration(seconds: 2));
  });

  test('timeout aborts the request and returns only a sanitized reason', () async {
    final abort = AbortController();
    final client = _StreamingClient((request) async {
      await (request as http.AbortableRequest).abortTrigger;
      throw http.RequestAbortedException(request.url);
    });
    await expectLater(
      SubtitleSourceLoader(
        client: client,
        timeout: const Duration(milliseconds: 20),
      ).load(SubtitleTrack.uri('https://example.invalid/subtitle.srt?api_key=secret'), abort: abort),
      throwsA(failure(SubtitleSourceFailure.timeout)),
    );
    expect(abort.isAborted, isTrue);
  });

  test('rejects unsupported tracks and already-cancelled work before opening anything', () async {
    final loader = SubtitleSourceLoader(client: MockClient((_) => throw StateError('Must not open a request')));
    await expectLater(
      loader.load(SubtitleTrack.uri('https://example.invalid/a.ass', codec: 'ass')),
      throwsA(failure(SubtitleSourceFailure.unsupported)),
    );
    await expectLater(
      loader.load(const SubtitleTrack(id: '3', codec: 'subrip')),
      throwsA(failure(SubtitleSourceFailure.unsupported)),
    );
    final abort = AbortController()..abort();
    await expectLater(
      loader.load(SubtitleTrack.uri('https://example.invalid/a.srt'), abort: abort),
      throwsA(failure(SubtitleSourceFailure.cancelled)),
    );
  });

  test('network errors expose neither tokens, URLs nor response dialogue', () async {
    final loader = SubtitleSourceLoader(client: MockClient((_) => throw StateError('secret-token $content')));
    try {
      await loader.load(SubtitleTrack.uri('https://example.invalid/a.srt?token=secret-token'));
      fail('Expected a sanitized failure');
    } on SubtitleSourceException catch (error) {
      expect(error.reason, SubtitleSourceFailure.unavailable);
      expect(error.toString(), 'SubtitleSourceException(unavailable)');
    }
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.sendRequest);

  final Future<http.StreamedResponse> Function(http.BaseRequest) sendRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => sendRequest(request);
}
