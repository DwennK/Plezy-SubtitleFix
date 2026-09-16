import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';

/// Deliberately false cached absence for the native recovery probe only.
/// The future segment is synthetic structural support required by the cache
/// writer, not evidence learned from audio. It lies outside the played excerpt.
TimelineMap wrongGapCacheFixture(SubtitleIndex index, {required double offset, required double gapEnd}) {
  final anchors = <SubtitleAnchor>[];
  for (var i = 0; i + 2 < index.words.length; i++) {
    final word = index.words[i];
    if (word.wordInCue != 0 || index.words[i + 2].cueOrdinal != word.cueOrdinal) continue;
    final subtitle = word.cueStart.inMicroseconds / 1e6;
    if (subtitle + offset <= gapEnd + 20) continue;
    anchors.add(
      SubtitleAnchor(
        word.cueOrdinal,
        subtitle,
        subtitle + offset,
        0.35,
        index.words.sublist(i, i + 3).map((word) => word.text).join(' '),
      ),
    );
    final support = const TimelineFitter().fit(anchors);
    if (support != null) {
      return TimelineMap(segments: [support], gaps: [TimelineGap(TimelineRegionKind.videoOnly, 0, gapEnd)]);
    }
    if (anchors.length >= 24) break;
  }
  throw StateError('insufficient-future-fixture-cues');
}
