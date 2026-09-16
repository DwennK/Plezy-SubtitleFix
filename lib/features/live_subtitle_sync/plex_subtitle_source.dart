import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../mpv/models.dart';
import '../../utils/media_server_http_client.dart';
import 'subtitle_source.dart';

/// Complete embedded SRT text without changing the player's native selection.
/// PMS needs a prepared session; a bare /subtitles request can return HTTP 400
/// or reuse stale session state. Only copy decisions are accepted for A/V/SRT.
class PlexSubtitleSource {
  PlexSubtitleSource({
    required this.baseUrl,
    required this.headers,
    required this.itemId,
    required this.mediaIndex,
    required this.partIndex,
    this.timeout = const Duration(minutes: 5),
  });

  final String baseUrl;
  final Map<String, String> headers;
  final String itemId;
  final int mediaIndex;
  final int partIndex;
  final Duration timeout;
  final _documents = <int, SubtitleDocument>{};

  Future<SubtitleDocument> load(int streamId, http.Client client, AbortController abort) async {
    String? ownedSession;
    try {
      // PMS uses its current selection, not subtitleStreamID. Verify it on both
      // sides of extraction, without ever writing the server's selection.
      final part = await _verifySelection(streamId, client, abort);
      final cached = _documents[streamId];
      if (cached != null) return cached;
      final streams = part['Stream'] as List;
      String codecFor(int type) {
        final candidates = streams.where((dynamic s) => s['streamType'] == type);
        final selected = candidates.where((dynamic s) => s['selected'] == true || s['selected'] == 1);
        final codec = (selected.firstOrNull ?? candidates.first)['codec'] as String;
        if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(codec)) {
          throw const SubtitleSourceException(SubtitleSourceFailure.unsupported);
        }
        return codec;
      }

      final sessionId = ownedSession = const Uuid().v4();
      final sourceHeaders = Map<String, String>.of(headers)
        ..remove('X-Plex-Client-Profile-Name')
        ..['X-Plex-Client-Identifier'] = 'plezy-livesync-$sessionId'
        ..['X-Plex-Platform'] = 'Chrome';
      final parameters = {
        'path': '/library/metadata/$itemId',
        'mediaIndex': '$mediaIndex',
        'partIndex': '$partIndex',
        'session': sessionId,
        'X-Plex-Platform': 'Chrome',
      };
      final decision = await _getJson(
        _uri('/video/:/transcode/universal/decision', {
          ...parameters,
          'protocol': 'hls',
          'directPlay': '0',
          'directStream': '1',
          'directStreamAudio': '1',
          'subtitles': 'sidecar',
          'X-Plex-Client-Profile-Extra':
              'add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts'
              '&videoCodec=${codecFor(1)}&audioCodec=${codecFor(2)}&replace=true)'
              '+add-transcode-target(type=subtitleProfile&context=all&protocol=http&container=srt'
              '&subtitleCodec=srt&replace=true)',
        }),
        sourceHeaders,
        client,
        abort,
      );
      final decisionStreams = [
        for (final item in decision['Metadata'] as List)
          for (final media in item['Media'] as List)
            for (final part in media['Part'] as List)
              for (final stream in part['Stream'] as List) stream,
      ];
      final av = decisionStreams.where((dynamic s) => s['streamType'] == 1 || s['streamType'] == 2);
      final subtitles = decisionStreams.where((dynamic s) => s['streamType'] == 3);
      if (av.isEmpty ||
          av.any((dynamic s) => s['decision'] != 'copy') ||
          subtitles.length != 1 ||
          subtitles.single['id'].toString() != streamId.toString() ||
          subtitles.single['codec'] != 'srt' ||
          subtitles.single['decision'] != 'copy') {
        throw const SubtitleSourceException(SubtitleSourceFailure.unsupported);
      }
      // No video/audio start URL is requested. Removing protocol from this
      // subtitle-only request gives the complete body, not buffered segments.
      final document =
          await SubtitleSourceLoader(
            client: client,
            timeout: timeout,
            allowedContentTypes: const {'text/srt', 'application/x-subrip', 'text/vtt', 'text/plain'},
          ).load(
            SubtitleTrack.uri(_uri('/video/:/transcode/universal/subtitles', parameters).toString(), codec: 'srt'),
            headers: {...sourceHeaders, 'Accept': 'text/srt,application/x-subrip,text/vtt,text/plain'},
            abort: abort,
          );
      await _verifySelection(streamId, client, abort);
      // At most one complete document, only for this playback source, in RAM.
      // Strict SRT parsing remains mandatory before analysis.
      _documents.clear();
      return _documents[streamId] = document;
    } on SubtitleSourceException {
      rethrow;
    } catch (_) {
      throw SubtitleSourceException(
        abort.isAborted ? SubtitleSourceFailure.cancelled : SubtitleSourceFailure.unavailable,
      );
    } finally {
      if (ownedSession != null) await _stopOwnedSession(ownedSession, client);
    }
  }

  Uri _uri(String path, [Map<String, String>? parameters]) =>
      Uri.parse(baseUrl).resolve(path).replace(queryParameters: parameters);

  Future<Map> _verifySelection(int streamId, http.Client client, AbortController abort) async {
    final container = await _getJson(_uri('/library/metadata/${Uri.encodeComponent(itemId)}'), headers, client, abort);
    final metadata = container['Metadata'] as List;
    final item = metadata.singleWhere((dynamic value) => value['ratingKey'].toString() == itemId);
    final part = item['Media'][mediaIndex]['Part'][partIndex] as Map;
    final selected = (part['Stream'] as List).where(
      (dynamic s) => s['streamType'] == 3 && (s['selected'] == true || s['selected'] == 1),
    );
    if (selected.length != 1 ||
        selected.single['id'].toString() != streamId.toString() ||
        !const {'srt', 'subrip'}.contains(selected.single['codec'])) {
      throw const SubtitleSourceException(SubtitleSourceFailure.unsupported);
    }
    return part;
  }

  Future<Map> _getJson(Uri uri, Map<String, String> requestHeaders, http.Client client, AbortController abort) async {
    Future<Map> read() async {
      abort.throwIfAborted();
      final request = http.AbortableRequest('GET', uri, abortTrigger: abort.trigger)
        ..followRedirects = false
        ..headers.addAll(requestHeaders)
        ..headers['Accept'] = 'application/json';
      final response = await client.send(request);
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw const SubtitleSourceException(SubtitleSourceFailure.unavailable);
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        abort.throwIfAborted();
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          throw const SubtitleSourceException(SubtitleSourceFailure.tooLarge);
        }
        bytes.addAll(chunk);
      }
      abort.throwIfAborted();
      return jsonDecode(utf8.decode(bytes))['MediaContainer'] as Map;
    }

    return read().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        abort.abort();
        throw const SubtitleSourceException(SubtitleSourceFailure.timeout);
      },
    );
  }

  Future<void> _stopOwnedSession(String session, http.Client client) async {
    final cleanup = AbortController();
    try {
      final request =
          http.AbortableRequest(
              'GET',
              _uri('/video/:/transcode/universal/stop', {'session': session}),
              abortTrigger: cleanup.trigger,
            )
            ..followRedirects = false
            ..headers.addAll(headers);
      final response = await client.send(request).timeout(const Duration(seconds: 5));
      await response.stream.listen(null).cancel();
    } catch (_) {
      // Cleanup failure cannot affect playback or expose URLs/credentials.
    } finally {
      cleanup.abort();
    }
  }
}
