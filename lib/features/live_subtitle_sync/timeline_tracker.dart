import 'temporal_aligner.dart';
import 'timeline_map.dart';

class TimelineCorrection {
  const TimelineCorrection(this.position, {this.predicted = false});
  final TimelinePosition position;
  final bool predicted;
}

/// Learns only from accepted, timestamped dialogue anchors. Predictions are
/// separate from the observed map: they expire in media time and never survive
/// a seek, rate change or capture discontinuity.
class TimelineTracker {
  static const predictionSeconds = 120.0;
  static const _fitter = TimelineFitter();
  TimelineMap _map = TimelineMap();
  final _pending = <int, SubtitleAnchor>{};
  final _continuous = <int, SubtitleAnchor>{};
  TimelineSegment? _prediction;

  TimelineMap get map => _map;

  void clear() {
    _map = TimelineMap();
    discontinuity();
  }

  void discontinuity() {
    _pending.clear();
    _continuous.clear();
    _prediction = null;
  }

  bool observe(List<SubtitleAnchor> anchors) {
    for (final anchor in anchors) {
      _pending[anchor.cue] = anchor;
    }
    while (_pending.length > 24) {
      _pending.remove(_pending.keys.first);
    }
    var fitted = _fitter.fit(_pending.values.toList());
    if (_continuous.isNotEmpty) {
      final observations = {..._continuous, ..._pending}.values.toList();
      final combined = observations.length <= 128 ? _fitter.fit(observations) : null;
      if (combined != null &&
          // Previously isolated cue starts can establish the slope once a
          // sufficiently long baseline exists. A rejected new observation
          // alone must never turn old evidence into a fresh confirmation.
          combined.anchors.any((a) => _pending.containsKey(a.cue)) &&
          _continuous.values.every((a) => (combined.mediaFor(a.subtitleTime) - a.mediaTime).abs() <= 0.8) &&
          _hasContinuousEvidence(combined)) {
        fitted = combined;
      }
    }
    if (fitted == null) return false;
    var candidate = fitted;

    // A cadence difference can already exceed the constant-fit tolerance
    // before six phrases span a minute. Retain the individually confirmed
    // clusters so that a later affine fit can explain them together.
    if (_continuous.isNotEmpty &&
        (candidate.mediaStart - _continuous.values.last.mediaTime > predictionSeconds ||
            _continuous.length + candidate.anchors.length > 128)) {
      _continuous.clear();
    }
    for (final anchor in candidate.anchors) {
      _continuous[anchor.cue] = anchor;
    }
    final continuousFit = _fitter.fit(_continuous.values.toList());
    if (continuousFit != null &&
        _continuous.values.every((a) => (continuousFit.mediaFor(a.subtitleTime) - a.mediaTime).abs() <= 0.8)) {
      candidate = continuousFit;
    }

    // Refine overlapping observations, or a short continuous extension. A
    // seek into an unknown region cannot join two distant endpoint clusters
    // into an invented, fully validated interval.
    for (final previous in _map.segments) {
      final overlap = candidate.subtitleStart < previous.subtitleEnd && previous.subtitleStart < candidate.subtitleEnd;
      final continuous =
          identical(previous, _prediction) &&
          candidate.mediaStart >= previous.mediaEnd &&
          candidate.mediaStart - previous.mediaEnd <= predictionSeconds;
      if (!overlap && !continuous) continue;
      final merged = _refine(previous, candidate);
      if (merged != null) candidate = merged;
    }
    try {
      final next = _map.withSegment(candidate);
      _map = next;
      // withSegment builds a new segment while preserving previous evidence.
      _prediction = next.segments.last;
      // A constant cluster may exclude an early, correctly timestamped cue
      // because the real offset is drifting. Retain it within the existing
      // bounded pending set until later observations can test an affine fit.
      // Outliers inside the now-confirmed domain have already been disproved.
      // They must not pair with a later bad timestamp to revoke this mapping.
      // Keep only observations outside the learned domain for future drift.
      _pending.removeWhere((_, anchor) => candidate.containsSubtitle(anchor.subtitleTime));
      return true;
    } on ArgumentError {
      // Confirmed but contradictory evidence must not extend the old offset.
      // Keep the earlier observed domains for navigation, without extrapolation.
      _prediction = null;
      _continuous.clear();
      return false;
    }
  }

  bool _hasContinuousEvidence(TimelineSegment segment) {
    final times = segment.anchors.map((a) => a.mediaTime).toList()..sort();
    for (var i = 1; i < times.length; i++) {
      if (times[i] - times[i - 1] > predictionSeconds) return false;
    }
    return true;
  }

  TimelineSegment? _refine(TimelineSegment previous, TimelineSegment candidate) {
    final observations = {
      for (final anchor in previous.anchors) anchor.cue: anchor,
      for (final anchor in candidate.anchors) anchor.cue: anchor,
    }.values.toList();
    if (observations.length > 128) return null;
    final merged = _fitter.fit(observations);
    if (merged == null ||
        merged.subtitleStart > previous.subtitleStart ||
        merged.subtitleEnd < previous.subtitleEnd ||
        merged.subtitleStart > candidate.subtitleStart ||
        merged.subtitleEnd < candidate.subtitleEnd ||
        observations.any((anchor) => (merged.mediaFor(anchor.subtitleTime) - anchor.mediaTime).abs() > 0.8)) {
      return null;
    }
    return merged;
  }

  TimelineCorrection correctionAt(double mediaTime, {double audioDelay = 0}) {
    if (!mediaTime.isFinite || !audioDelay.isFinite) {
      return const TimelineCorrection(TimelinePosition(TimelineRegionKind.unknown));
    }
    // Capture anchors use decoded audio PTS, before mpv's manual audio delay.
    // A delayed voice reaches video time M at audio-source time M - delay.
    final audio = _atAudioTime(mediaTime - audioDelay);
    final position = audio.position;
    if (position.automaticDelay == null) return audio;
    return TimelineCorrection(
      TimelinePosition(
        position.kind,
        subtitleTime: position.subtitleTime,
        automaticDelay: position.automaticDelay! + audioDelay,
      ),
      predicted: audio.predicted,
    );
  }

  TimelineCorrection _atAudioTime(double mediaTime) {
    final observed = _map.atMedia(mediaTime);
    if (observed.kind != TimelineRegionKind.unknown) return TimelineCorrection(observed);
    final active = _prediction;
    if (active == null ||
        !mediaTime.isFinite ||
        mediaTime < active.mediaEnd ||
        mediaTime - active.mediaEnd > predictionSeconds ||
        _map.segments.any((s) => s.mediaStart >= active.mediaEnd && s.mediaStart <= mediaTime) ||
        _map.gaps.any(
          (g) =>
              g.kind == TimelineRegionKind.videoOnly && g.start >= active.mediaEnd && g.start <= mediaTime ||
              g.kind == TimelineRegionKind.subtitleOnly &&
                  g.start >= active.subtitleEnd &&
                  g.start <= active.subtitleFor(mediaTime),
        )) {
      return const TimelineCorrection(TimelinePosition(TimelineRegionKind.unknown));
    }
    final subtitleTime = active.subtitleFor(mediaTime);
    return TimelineCorrection(
      TimelinePosition(
        TimelineRegionKind.aligned,
        subtitleTime: subtitleTime,
        automaticDelay: mediaTime - subtitleTime,
      ),
      predicted: true,
    );
  }
}
