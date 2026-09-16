import 'dart:math' as math;

import 'temporal_aligner.dart';
import 'text_normalization.dart';

/// All values are seconds in the original media/subtitle timelines. Domains
/// are half-open: a boundary belongs to the region on its right.
enum TimelineRegionKind { aligned, unknown, videoOnly, subtitleOnly }

class TimelinePosition {
  const TimelinePosition(this.kind, {this.subtitleTime, this.automaticDelay});
  final TimelineRegionKind kind;
  final double? subtitleTime;
  final double? automaticDelay;
}

/// Canonical affine parameters: media = slope * subtitle + offset. Media bounds
/// are derived, never stored independently from the source domain and mapping.
class TimelineSegment {
  TimelineSegment({
    required this.subtitleStart,
    required this.subtitleEnd,
    required this.slope,
    required this.offset,
    required this.uncertainty,
    required List<SubtitleAnchor> anchors,
  }) : anchors = List.unmodifiable(anchors) {
    if (![subtitleStart, subtitleEnd, slope, offset, uncertainty].every((v) => v.isFinite) ||
        subtitleStart < 0 ||
        subtitleEnd <= subtitleStart ||
        slope < 0.9 ||
        slope > 1.1 ||
        uncertainty < 0 ||
        uncertainty > 1 ||
        !mediaStart.isFinite ||
        !mediaEnd.isFinite ||
        mediaEnd <= 0 ||
        anchors.length < 2 ||
        anchors.length > 128 ||
        anchors.any(
          (a) =>
              !a.subtitleTime.isFinite ||
              !a.mediaTime.isFinite ||
              !a.uncertainty.isFinite ||
              a.uncertainty < 0 ||
              a.uncertainty > 1 ||
              a.subtitleTime < subtitleStart ||
              a.subtitleTime >= subtitleEnd ||
              (a.mediaTime - mediaFor(a.subtitleTime)).abs() > 0.8,
        )) {
      throw ArgumentError('Invalid timeline segment');
    }
  }

  final double subtitleStart;
  final double subtitleEnd;
  final double slope;
  final double offset;
  final double uncertainty;
  final List<SubtitleAnchor> anchors;
  double get mediaStart => slope * subtitleStart + offset;
  double get mediaEnd => slope * subtitleEnd + offset;
  double mediaFor(double subtitle) => slope * subtitle + offset;
  double subtitleFor(double media) => (media - offset) / slope;
  bool containsMedia(double time) => time >= mediaStart && time < mediaEnd;
  bool containsSubtitle(double time) => time >= subtitleStart && time < subtitleEnd;
}

/// An explicitly confirmed absence, not an inference from silence or a failed
/// transcript. The caller must supply evidence before inserting one of these.
class TimelineGap {
  TimelineGap(this.kind, this.start, this.end) {
    if ((kind != TimelineRegionKind.videoOnly && kind != TimelineRegionKind.subtitleOnly) ||
        !start.isFinite ||
        !end.isFinite ||
        start < 0 ||
        end <= start) {
      throw ArgumentError('Invalid timeline gap');
    }
  }
  final TimelineRegionKind kind;
  // Media seconds for videoOnly; subtitle seconds for subtitleOnly.
  final double start;
  final double end;
}

/// An immutable, bounded set of learned regions. Unobserved areas remain
/// unknown; merely extending the last offset across an edit is not allowed.
class TimelineMap {
  TimelineMap({List<TimelineSegment> segments = const [], List<TimelineGap> gaps = const []})
    : segments = List.unmodifiable(segments),
      gaps = List.unmodifiable(gaps) {
    if (segments.length > 128 || gaps.length > 128) throw ArgumentError('Timeline exceeds bounds');
    _checkIntervals([
      for (final s in segments) (s.mediaStart, s.mediaEnd),
      for (final g in gaps.where((g) => g.kind == TimelineRegionKind.videoOnly)) (g.start, g.end),
    ]);
    _checkIntervals([
      for (final s in segments) (s.subtitleStart, s.subtitleEnd),
      for (final g in gaps.where((g) => g.kind == TimelineRegionKind.subtitleOnly)) (g.start, g.end),
    ]);
    final ordered = segments.toList()..sort((a, b) => a.subtitleStart.compareTo(b.subtitleStart));
    for (var i = 1; i < ordered.length; i++) {
      if (ordered[i].mediaStart < ordered[i - 1].mediaEnd) throw ArgumentError('Non-monotonic timeline');
    }
  }

  final List<TimelineSegment> segments;
  final List<TimelineGap> gaps;

  static void _checkIntervals(List<(double, double)> intervals) {
    intervals.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < intervals.length; i++) {
      if (intervals[i].$1 < intervals[i - 1].$2) throw ArgumentError('Overlapping timeline regions');
    }
  }

  /// Add a separately confirmed region, or refine a region whose entire
  /// previous evidence still agrees. An incompatible overlapping observation
  /// must be resolved at a scene boundary by the learner, never overwritten.
  TimelineMap withSegment(TimelineSegment candidate) {
    final retained = <TimelineSegment>[];
    final evidence = {for (final anchor in candidate.anchors) anchor.cue: anchor};
    for (final previous in segments) {
      final sourceOverlap =
          candidate.subtitleStart < previous.subtitleEnd && previous.subtitleStart < candidate.subtitleEnd;
      final mediaOverlap = candidate.mediaStart < previous.mediaEnd && previous.mediaStart < candidate.mediaEnd;
      if (!sourceOverlap && !mediaOverlap) {
        retained.add(previous);
        continue;
      }
      if (candidate.subtitleStart > previous.subtitleStart ||
          candidate.subtitleEnd < previous.subtitleEnd ||
          previous.anchors.any((anchor) => (candidate.mediaFor(anchor.subtitleTime) - anchor.mediaTime).abs() > 0.8)) {
        throw ArgumentError('Conflicting timeline evidence');
      }
      for (final anchor in previous.anchors) {
        // The candidate may refine a previously observed cue. Preserve the
        // accepted new timestamp; only carry forward cues not reobserved.
        evidence.putIfAbsent(anchor.cue, () => anchor);
      }
    }
    final refined = TimelineSegment(
      subtitleStart: candidate.subtitleStart,
      subtitleEnd: candidate.subtitleEnd,
      slope: candidate.slope,
      offset: candidate.offset,
      uncertainty: candidate.uncertainty,
      anchors: evidence.values.toList(),
    );
    return TimelineMap(segments: [...retained, refined], gaps: gaps);
  }

  TimelinePosition atMedia(double time) {
    if (!time.isFinite || time < 0) return const TimelinePosition(TimelineRegionKind.unknown);
    for (final gap in gaps) {
      if (gap.kind == TimelineRegionKind.videoOnly && time >= gap.start && time < gap.end) {
        return const TimelinePosition(TimelineRegionKind.videoOnly);
      }
    }
    for (final segment in segments) {
      if (segment.containsMedia(time)) {
        final subtitle = segment.subtitleFor(time);
        return TimelinePosition(TimelineRegionKind.aligned, subtitleTime: subtitle, automaticDelay: time - subtitle);
      }
    }
    return const TimelinePosition(TimelineRegionKind.unknown);
  }

  TimelineRegionKind atSubtitle(double time) {
    if (!time.isFinite || time < 0) return TimelineRegionKind.unknown;
    for (final gap in gaps) {
      if (gap.kind == TimelineRegionKind.subtitleOnly && time >= gap.start && time < gap.end) {
        return TimelineRegionKind.subtitleOnly;
      }
    }
    return segments.any((s) => s.containsSubtitle(time)) ? TimelineRegionKind.aligned : TimelineRegionKind.unknown;
  }
}

/// Robust fitting from independent cue starts. Slopes require at least six
/// phrases spanning a minute of both timelines. Thresholds are heuristics;
/// corpus validation, not this class, establishes their real accuracy.
class TimelineFitter {
  const TimelineFitter();

  /// Sanitized, independent cue starts. Independence alone does not establish
  /// a timing model: callers still need a fit before applying a correction.
  List<SubtitleAnchor> independentObservations(List<SubtitleAnchor> observations) {
    final independent = <SubtitleAnchor>[];
    final cues = <int>{};
    final phrases = <String>{};
    const normalizer = DialogueNormalizer();
    for (final anchor in observations.take(128)) {
      final phrase = normalizer.words(anchor.phrase).join(' ');
      if (!anchor.subtitleTime.isFinite ||
          !anchor.mediaTime.isFinite ||
          !anchor.uncertainty.isFinite ||
          anchor.uncertainty < 0 ||
          anchor.uncertainty > 1 ||
          anchor.offset.abs() > 600 ||
          anchor.subtitleTime < 0 ||
          anchor.mediaTime < 0 ||
          phrase.split(' ').length < 3 ||
          cues.contains(anchor.cue) ||
          phrases.contains(phrase)) {
        continue;
      }
      cues.add(anchor.cue);
      phrases.add(phrase);
      independent.add(anchor);
    }
    independent.sort((a, b) => a.subtitleTime.compareTo(b.subtitleTime));
    return independent;
  }

  /// The fitted domain ends at the last observed anchor (inclusive to one
  /// microsecond). Prediction outside that domain requires a separate policy.
  TimelineSegment? fit(List<SubtitleAnchor> observations) {
    final independent = independentObservations(observations);
    if (independent.length < 2 || independent.last.subtitleTime - independent.first.subtitleTime < 3) return null;

    var slope = 1.0;
    var offset = _median(independent.map((a) => a.offset));
    final sourceSpan = independent.last.subtitleTime - independent.first.subtitleTime;
    final mediaTimes = independent.map((a) => a.mediaTime).toList()..sort();
    if (independent.length >= 6 && sourceSpan >= 60 && mediaTimes.last - mediaTimes.first >= 60) {
      final slopes = <double>[];
      for (var i = 0; i < independent.length; i++) {
        for (var j = i + 1; j < independent.length; j++) {
          final span = independent[j].subtitleTime - independent[i].subtitleTime;
          if (span < 30) continue;
          final candidate = (independent[j].mediaTime - independent[i].mediaTime) / span;
          if (candidate >= 0.9 && candidate <= 1.1) slopes.add(candidate);
        }
      }
      if (slopes.isNotEmpty) {
        final candidate = _median(slopes);
        final intercept = _median(independent.map((a) => a.mediaTime - candidate * a.subtitleTime));
        final constantResidual = _median(independent.map((a) => (a.offset - offset).abs()));
        final affineResidual = _median(
          independent.map((a) => (a.mediaTime - candidate * a.subtitleTime - intercept).abs()),
        );
        if ((candidate - 1).abs() * sourceSpan >= 0.5 && constantResidual - affineResidual >= 0.15) {
          slope = candidate;
          offset = intercept;
        }
      }
    }
    final inliers = independent.where((a) => (a.mediaTime - slope * a.subtitleTime - offset).abs() <= 0.8).toList();
    if (inliers.length < 2 ||
        inliers.length < independent.length * 0.75 ||
        inliers.last.subtitleTime - inliers.first.subtitleTime < 3) {
      return null;
    }
    final uncertainty = math.max(
      _median(inliers.map((a) => a.uncertainty)),
      _median(inliers.map((a) => (a.mediaTime - slope * a.subtitleTime - offset).abs())),
    );
    return TimelineSegment(
      subtitleStart: inliers.first.subtitleTime,
      subtitleEnd: inliers.last.subtitleTime + 0.000001,
      slope: slope,
      offset: offset,
      uncertainty: uncertainty,
      anchors: inliers,
    );
  }

  static double _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    return sorted.length.isOdd
        ? sorted[sorted.length ~/ 2]
        : (sorted[sorted.length ~/ 2 - 1] + sorted[sorted.length ~/ 2]) / 2;
  }
}
