import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/mapping_cache.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/mpv/models.dart';

import '../../tool/livesync_wrong_gap_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final index = SubtitleIndex(
    ParsedSubtitles(SubtitleEncoding.utf8, [
      for (final (i, time, text) in [
        (0, 100, 'Bring the silver lantern'),
        (1, 110, 'Walk across that wooden bridge'),
        (2, 300, 'Open this heavy door'),
        (3, 310, 'Please find another path'),
      ])
        SubtitleCue(
          ordinal: i,
          sourceId: null,
          start: Duration(seconds: time),
          end: Duration(seconds: time + 4),
          text: text,
          timingSuffix: '',
        ),
    ]),
  );
  for (final (offset, duration) in [(-100.0, 75.0), (90.0, 165.0)]) {
    test('corrupted gap fixture survives the real cache codec at offset $offset', () async {
      final directory = await Directory.systemTemp.createTemp('livesync-wrong-gap-');
      try {
        final media = File('${directory.path}/fixture.mkv');
        await media.writeAsBytes([1, 2, 3]);
        final key = MappingCacheKey.create(
          (await LiveSyncMediaIdentity.local(media.path))!,
          const AudioTrack(id: '1', codec: 'pcm_s16le', language: 'eng', channels: 6),
          sha256.convert([4, 5, 6]).toString(),
        )!;
        final cache = MappingCache(Directory('${directory.path}/cache'));
        final map = wrongGapCacheFixture(index, offset: offset, gapEnd: duration);
        await cache.write(key, map, generation: cache.generation);
        final restored = (await cache.read(key, index))!;
        expect(restored.atMedia(duration / 2).kind, TimelineRegionKind.videoOnly);
        expect(restored.segments.single.mediaStart, greaterThan(duration + 20));
        expect(restored.segments.single.offset, offset);
        expect(restored.gaps.single.start, 0);
        expect(restored.gaps.single.end, duration);
      } finally {
        await directory.delete(recursive: true);
      }
    });
  }
}
