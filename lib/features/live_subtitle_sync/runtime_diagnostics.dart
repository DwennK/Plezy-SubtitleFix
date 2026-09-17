import 'dart:convert';

/// Bounded, opt-in developer output. Unknown fields and all free text are
/// discarded before encoding; this must never become an application log sink.
class LiveSyncRuntimeDiagnostics {
  LiveSyncRuntimeDiagnostics(this.write, {this.maximumEvents = 2048});

  final void Function(String) write;
  final int maximumEvents;
  int _events = 0;
  bool _failed = false;

  static const prefix = 'LIVESYNC_DIAGNOSTIC ';
  static const _numbers = {
    'attempt',
    'generation',
    'continuity',
    'inferenceSeconds',
    'matchingMs',
    'windowStart',
    'windowEnd',
    'similarity',
    'competitor',
    'contextWindows',
    'startupSubtitlesMs',
    'restoredSegments',
    'restoredGaps',
    'startupCaptureMs',
    'startupReadyMs',
    'startupBufferedSamples',
    'learnedMediaStart',
    'learnedMediaEnd',
    'learnedSlope',
    'learnedSegments',
    'analysisRequest',
    'analysisIntervalMs',
    'analysisWindowSeconds',
    'elapsedMs',
    'automaticOffset',
    'latestAnchorMediaTime',
    'previousContinuity',
    'bufferedSamples',
  };
  static const _booleans = {
    'validPrefixOnly',
    'segmentedMatch',
    'mappingCacheEligible',
    'captureReadyBeforeSubtitles',
    'activityVoicePresent',
    'activityTimingMismatch',
    'speechTimingRejected',
  };
  static const _enums = {
    'phase': {'off', 'loadingSubtitles', 'downloading', 'analyzing', 'synced', 'resyncing', 'unable', 'unsupported'},
    'reason': {
      'platform',
      'englishTracks',
      'externalSrt',
      'passthrough',
      'surround',
      'source',
      'model',
      'nativeRuntime',
      'noMatch',
    },
    'match': {'matched', 'insufficientDialogue', 'noCandidate', 'ambiguous'},
    'inferenceBackend': {'portable-cpu', 'avx2-cpu', 'metal'},
    'failure': {
      'noPcm',
      'libraryUnavailable',
      'incompatibleAbi',
      'captureUnavailable',
      'inferenceUnavailable',
      'invalidOutput',
    },
  };
  static const _rejections = {
    'normalizationMismatch',
    'cueBeginningAbsent',
    'cueBeginningNotMatched',
    'beginningLowConfidence',
    'beginningInvalidTimestamp',
    'beginningAtWindowEdge',
    'beginningTooWide',
    'phraseNotMatched',
    'phraseLowConfidence',
    'phraseInvalidTimestamp',
    'shortCueContextDiscontinuous',
    'beginningUnsupportedSpeech',
  };

  void record(Map<String, Object?> event) {
    if (_failed || _events >= maximumEvents) return;
    final safe = <String, Object?>{};
    for (final entry in event.entries) {
      final value = entry.value;
      if (_numbers.contains(entry.key) && value is num && value.isFinite ||
          _booleans.contains(entry.key) && value is bool ||
          _enums[entry.key]?.contains(value) == true) {
        safe[entry.key] = value;
      }
    }
    final rejections = event['anchorRejections'];
    if (rejections is Map) {
      safe['anchorRejections'] = {
        for (final key in _rejections)
          if (rejections[key] is int && (rejections[key] as int) >= 0) key: rejections[key],
      };
    }
    final anchors = event['anchors'];
    if (anchors is List) {
      safe['anchors'] = [
        for (final anchor in anchors.take(64))
          if (anchor is Map)
            {
              for (final key in const ['cue', 'offset'])
                if (anchor[key] is num && (anchor[key] as num).isFinite) key: anchor[key],
            },
      ];
    }
    if (safe.isEmpty) return;
    try {
      write('$prefix${jsonEncode({'sequence': ++_events, ...safe})}');
    } catch (_) {
      // A closed diagnostic pipe must not interrupt media playback.
      _failed = true;
    }
  }
}
