import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../../mpv/models.dart';
import '../../utils/isolate_helper.dart';
import '../../utils/media_server_http_client.dart';

enum SubtitleSourceFailure { unsupported, unavailable, tooLarge, cancelled, timeout }

/// Deliberately excludes the URI, response body, token and underlying exception.
class SubtitleSourceException implements Exception {
  const SubtitleSourceException(this.reason);

  final SubtitleSourceFailure reason;

  @override
  String toString() => 'SubtitleSourceException(${reason.name})';
}

/// The complete original file, held in memory only. Never identifies a media
/// item on its own; the content hash is one component of a future mapping key.
class SubtitleDocument {
  SubtitleDocument._(Uint8List bytes, this.contentHash) : bytes = bytes.asUnmodifiableView();

  final Uint8List bytes;
  final String contentHash;

  @override
  String toString() => 'SubtitleDocument(${bytes.length} bytes)';
}

/// Reads an already resolved sidecar, using the caller's existing server
/// transport and headers. Does not construct server URLs, log them, open media,
/// extract embedded subtitles, or change the selected track/source file.
class SubtitleSourceLoader {
  const SubtitleSourceLoader({
    required this.client,
    this.maximumBytes = 4 * 1024 * 1024,
    this.timeout = const Duration(seconds: 20),
  });

  /// Borrowed transport: keeps Plezy's certificate, proxy and native HTTP
  /// behavior. Its owner, not this loader, controls its lifetime.
  final http.Client client;
  final int maximumBytes;
  final Duration timeout;

  Future<SubtitleDocument> load(
    SubtitleTrack track, {
    Map<String, String> headers = const {},
    AbortController? abort,
  }) async {
    final cancellation = abort ?? AbortController();
    try {
      return await _load(track, headers, cancellation).timeout(
        timeout,
        onTimeout: () {
          cancellation.abort();
          throw const SubtitleSourceException(SubtitleSourceFailure.timeout);
        },
      );
    } on SubtitleSourceException {
      rethrow;
    } catch (_) {
      throw SubtitleSourceException(
        cancellation.isAborted ? SubtitleSourceFailure.cancelled : SubtitleSourceFailure.unavailable,
      );
    }
  }

  Future<SubtitleDocument> _load(SubtitleTrack track, Map<String, String> headers, AbortController abort) async {
    abort.throwIfAborted();
    final location = track.uri;
    if (!track.isExternal || track.isContainer || location == null || location.isEmpty || maximumBytes <= 0) {
      throw const SubtitleSourceException(SubtitleSourceFailure.unsupported);
    }
    final uri = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(location) ? Uri.file(location, windows: true) : Uri.parse(location);
    final codec = track.codec?.toLowerCase();
    if (!(codec == 'srt' || codec == 'subrip' || (codec == null && uri.path.toLowerCase().endsWith('.srt')))) {
      throw const SubtitleSourceException(SubtitleSourceFailure.unsupported);
    }
    Stream<List<int>> stream;
    if (uri.scheme.isEmpty || uri.scheme == 'file') {
      final file = uri.scheme.isEmpty ? File(location) : File.fromUri(uri);
      if (await file.length() > maximumBytes) {
        throw const SubtitleSourceException(SubtitleSourceFailure.tooLarge);
      }
      stream = file.openRead();
    } else if (uri.scheme == 'http' || uri.scheme == 'https') {
      final request = http.AbortableRequest('GET', uri, abortTrigger: abort.trigger)..headers.addAll(headers);
      final response = await client.send(request);
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw const SubtitleSourceException(SubtitleSourceFailure.unavailable);
      }
      if ((response.contentLength ?? 0) > maximumBytes) {
        await response.stream.listen(null).cancel();
        throw const SubtitleSourceException(SubtitleSourceFailure.tooLarge);
      }
      stream = response.stream;
    } else {
      throw const SubtitleSourceException(SubtitleSourceFailure.unsupported);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      abort.throwIfAborted();
      if (builder.length + chunk.length > maximumBytes) {
        throw const SubtitleSourceException(SubtitleSourceFailure.tooLarge);
      }
      builder.add(chunk);
    }
    abort.throwIfAborted();
    final bytes = builder.takeBytes();
    final hash = await tryIsolateRun(() => crypto.sha256.convert(bytes).toString());
    abort.throwIfAborted();
    return SubtitleDocument._(bytes, hash);
  }
}
