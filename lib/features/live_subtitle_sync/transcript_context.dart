import 'native_bindings.dart';
import 'subtitle_index.dart';
import 'temporal_aligner.dart';
import 'text_normalization.dart';
import 'transcript_matcher.dart';

/// Two recent windows, in memory only. Matching may use their combined text,
/// but every token keeps its original media timestamp and edge validity.
/// A seek, PCM discontinuity or missing capture breaks context. Stale results
/// are ignored without replacing newer evidence.
class TranscriptContext {
  NativeTranscript? _previous;

  void clear() => _previous = null;

  NativeTranscript? add(NativeTranscript current) {
    if (!current.windowStart.isFinite || !current.windowEnd.isFinite || current.windowEnd <= current.windowStart) {
      clear();
      return null;
    }
    final previous = _previous;
    if (previous != null &&
        previous.generation == current.generation &&
        previous.continuity == current.continuity &&
        current.windowEnd <= previous.windowEnd) {
      return null;
    }
    _previous = current;
    if (previous == null ||
        previous.validPrefixOnly ||
        previous.generation != current.generation ||
        previous.continuity != current.continuity ||
        current.windowStart < previous.windowStart ||
        current.windowStart - previous.windowEnd > 1 ||
        current.windowEnd - previous.windowStart > 60) {
      return null;
    }
    // Never concatenate two recognitions of the same audio. The newest window
    // owns the overlap; a partially overlapped older segment is dropped whole.
    final earlier = previous.segments.where((segment) {
      if (segment.end > current.windowStart) return false;
      if (previous.windowEnd <= current.windowStart) return true;
      // Segment bounds are coarser than DTW token bounds. A token can extend
      // beyond its segment's nominal end; retain only proven non-overlap.
      return segment.tokens.every((token) => token.hasTimestamp && token.end <= current.windowStart);
    }).toList();
    if (earlier.isEmpty || current.segments.isEmpty) return null;
    final segments = [
      for (final segment in earlier) _withOriginalEdges(segment, previous),
      for (final segment in current.segments) _withOriginalEdges(segment, current),
    ];
    if (segments.length > 128 || segments.fold<int>(0, (size, segment) => size + segment.text.length) > 32768) {
      return null;
    }
    return NativeTranscript(
      current.generation,
      current.continuity,
      previous.windowStart,
      current.windowEnd,
      previous.elapsed + current.elapsed,
      segments,
      validPrefixOnly: previous.validPrefixOnly || current.validPrefixOnly,
    );
  }

  static NativeTranscriptSegment _withOriginalEdges(NativeTranscriptSegment segment, NativeTranscript source) =>
      NativeTranscriptSegment(segment.text, segment.start, segment.end, [
        for (final token in segment.tokens)
          NativeTranscriptToken(
            token.text,
            token.start,
            token.end,
            token.score,
            token.hasTimestamp && token.start >= source.windowStart + 0.1 && token.end <= source.windowEnd,
            speechSupport: token.speechSupport,
          ),
      ]);
}

class TranscriptEvidence {
  const TranscriptEvidence(
    this.match,
    this.anchors,
    this.windowCount, {
    this.segmented = false,
    this.anchorRejections = const {},
    this.speechTimingRejected = false,
  });
  final TranscriptMatchResult match;
  final List<SubtitleAnchor> anchors;
  final int windowCount;
  final bool segmented;

  /// May request one retry; this never authorizes a mapping change.
  final bool speechTimingRejected;

  /// Opt-in counts only. Never includes phrases, token text or audio.
  final Map<String, int> anchorRejections;
}

/// First try the complete current window. If noise outside the authored
/// dialogue prevents a match, inspect contiguous groups of up to three ASR
/// segments. This bounded search keeps the same textual quality thresholds.
/// All accepted anchors reach the estimator, including conflicting groups;
/// choosing only the strongest group could hide a contradictory edition.
TranscriptEvidence _matchWindow(NativeTranscript source, SubtitleIndex index, int windowCount, bool diagnostics) {
  final rejected = <String, int>{};
  final whole = const TranscriptMatcher().find(source.segments.map((segment) => segment.text).join(' '), index);
  if (whole.status == TranscriptMatchStatus.matched) {
    return TranscriptEvidence(
      whole,
      const TemporalAligner().anchors(source, index, whole.passage!, rejectionCounts: rejected),
      windowCount,
      anchorRejections: diagnostics ? rejected : const {},
      speechTimingRejected: (rejected['beginningUnsupportedSpeech'] ?? 0) > 0,
    );
  }
  // Budget viable groups, not raw segments: short noise fragments must not
  // hide useful dialogue. These filters are necessary conditions of the
  // unchanged matcher (six words and at least 60% exact correspondences).
  // Enumerate all candidates before matching; never truncate competitors.
  if (source.segments.length > 128 ||
      source.segments.fold<int>(0, (size, segment) => size + segment.text.length) > 32768) {
    return TranscriptEvidence(whole, const [], windowCount);
  }
  const matcher = TranscriptMatcher();
  final groups = <List<NativeTranscriptSegment>>[];
  for (var start = 0; start < source.segments.length; start++) {
    for (var count = 1; count <= 3 && start + count <= source.segments.length; count++) {
      if (start == 0 && count == source.segments.length) continue;
      final segments = source.segments.sublist(start, start + count);
      final words = const DialogueNormalizer().words(segments.map((segment) => segment.text).join(' '));
      if (words.length < matcher.minimumWords ||
          words.length > 128 ||
          words.where((word) => index.positionsOf(word).isNotEmpty).length / words.length < 0.6) {
        continue;
      }
      groups.add(segments);
      if (groups.length > 21) return TranscriptEvidence(whole, const [], windowCount);
    }
  }
  TranscriptMatchResult? best;
  final anchors = <int, SubtitleAnchor>{};
  for (final segments in groups) {
    final match = matcher.find(segments.map((segment) => segment.text).join(' '), index);
    if (match.status != TranscriptMatchStatus.matched) continue;
    final selected = NativeTranscript(
      source.generation,
      source.continuity,
      source.windowStart,
      source.windowEnd,
      source.elapsed,
      segments,
      validPrefixOnly: source.validPrefixOnly,
    );
    final matched = const TemporalAligner().anchors(selected, index, match.passage!, rejectionCounts: rejected);
    for (final anchor in matched) {
      final previous = anchors[anchor.cue];
      if (previous != null && (previous.mediaTime - anchor.mediaTime).abs() > 0.8) {
        return TranscriptEvidence(const TranscriptMatchResult(TranscriptMatchStatus.ambiguous), const [], windowCount);
      }
      anchors.putIfAbsent(anchor.cue, () => anchor);
    }
    if (matched.isNotEmpty && (best == null || match.passage!.similarity > best.passage!.similarity)) best = match;
  }
  return best == null
      ? TranscriptEvidence(
          whole,
          const [],
          windowCount,
          anchorRejections: diagnostics ? rejected : const {},
          speechTimingRejected: (rejected['beginningUnsupportedSpeech'] ?? 0) > 0,
        )
      : TranscriptEvidence(
          best,
          List.unmodifiable(anchors.values),
          windowCount,
          segmented: true,
          anchorRejections: diagnostics ? rejected : const {},
          speechTimingRejected: (rejected['beginningUnsupportedSpeech'] ?? 0) > 0,
        );
}

/// Context can resolve a short or ambiguous passage, while keeping every
/// original timestamp and the matcher's word, similarity and ambiguity gates.
TranscriptEvidence matchTranscriptEvidence(
  NativeTranscript transcript,
  SubtitleIndex index, {
  NativeTranscript? context,
  bool diagnostics = false,
}) {
  final current = _matchWindow(transcript, index, 1, diagnostics);
  if (current.match.status == TranscriptMatchStatus.matched || context == null) return current;
  final combined = _matchWindow(context, index, 2, diagnostics);
  return combined.match.status == TranscriptMatchStatus.matched ? combined : current;
}
