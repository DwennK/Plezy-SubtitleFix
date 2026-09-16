import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/media_identity.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/playback_context.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/playback_session.dart';

void main() {
  PlaybackSession session({
    String source = 'v2',
    String url = 'https://host?token=one',
    bool transcoding = false,
    bool offline = false,
    int part = 2,
    int? updatedAt = 100,
  }) => PlaybackSession(
    qualityPreset: TranscodeQualityPreset.original,
    context: PlaybackContext(
      metadata: MediaItem.plex(id: 'item', kind: MediaKind.movie, serverId: 'server', updatedAt: updatedAt),
      sourceKind: PlaybackSourceKind.remoteDirect,
      reportingMode: PlaybackReportingMode.online,
      result: PlaybackInitializationResult(
        isTranscoding: transcoding,
        isOffline: offline,
        selectedMediaIndex: 0,
        availableVersions: const [
          MediaVersion(
            id: 'v1',
            parts: [MediaPart(id: '1', sizeBytes: 1000, durationMs: 10000)],
          ),
          MediaVersion(
            id: 'v2',
            parts: [MediaPart(id: '2', sizeBytes: 2000, durationMs: 20000)],
          ),
        ],
        mediaInfo: MediaSourceInfo(
          videoUrl: url,
          audioTracks: [],
          subtitleTracks: [],
          chapters: [],
          mediaSourceId: source,
          partId: part,
        ),
      ),
    ),
  );

  test('authoritative source and part win over a stale index and temporary URL', () {
    final selected = liveSyncIdentityForSession(session())!;
    expect(liveSyncIdentityForSession(session(url: 'https://another?token=two'))!.digest, selected.digest);
    expect(liveSyncIdentityForSession(session(source: 'v1', part: 1))!.digest, isNot(selected.digest));
    expect(liveSyncIdentityForSession(session(updatedAt: 101))!.digest, isNot(selected.digest));
  });

  test('ambiguous or transformed server media has no persistent identity', () {
    for (final value in [
      session(source: 'missing'),
      session(part: 999),
      session(updatedAt: null),
      session(transcoding: true),
      session(offline: true),
    ]) {
      expect(liveSyncIdentityForSession(value), isNull);
    }
  });
}
