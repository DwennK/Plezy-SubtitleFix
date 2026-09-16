import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../mpv/player/player_native.dart';
import '../../utils/media_server_http_client.dart';
import 'analysis_cadence.dart';
import 'analysis_worker.dart';
import 'model_manager.dart';
import 'mapping_cache.dart';
import 'native_bindings.dart';
import 'player_attachment.dart';
import 'pcm_availability.dart';
import 'runtime_paths.dart';
import 'subtitle_index.dart';
import 'subtitle_parser.dart';
import 'subtitle_source.dart';
import 'startup.dart';
import 'timeline_map.dart';
import 'timeline_tracker.dart';
import 'transcript_context.dart';
import 'transcript_matcher.dart';

enum LiveSyncPhase { off, loadingSubtitles, downloading, analyzing, synced, resyncing, unable, unsupported }

enum LiveSyncReason {
  platform,
  englishTracks,
  externalSrt,
  passthrough,
  surround,
  source,
  model,
  nativeRuntime,
  noMatch,
}

class _Resources {
  _Resources(this.transport, this.models, this.mappings);
  final MediaServerHttpClient transport;
  final LiveSyncModelManager models;
  final MappingCache mappings;
}

class LiveSubtitleSyncController extends ChangeNotifier {
  LiveSubtitleSyncController._(this.player) {
    LiveSyncPlayerAttachment.sessions[player] = LiveSyncPlayerAttachment(disable);
    _subscriptions.add(player.streams.playheadJump.listen((target) => unawaited(_reset(target: target))));
    _subscriptions.add(player.streams.rate.listen((_) => unawaited(_reset())));
    _subscriptions.add(
      player.streams.track.listen((selection) {
        final key = '${selection.audio?.id}|${selection.subtitle?.id}';
        if (_trackKey != key && _requested) unawaited(_restartForTracks());
      }),
    );
  }
  static final _controllers = Expando<LiveSubtitleSyncController>();
  static Future<_Resources>? _resources;
  static LiveSubtitleSyncController forPlayer(PlayerNative player) =>
      _controllers[player] ??= LiveSubtitleSyncController._(player);

  static Future<_Resources> _prepareResources() => _resources ??=
      () async {
        final support = await getApplicationSupportDirectory();
        final transport = MediaServerHttpClient();
        return _Resources(
          transport,
          LiveSyncModelManager(
            directory: Directory(p.join(support.path, 'live-subtitle-sync', 'models')),
            client: transport.inner,
          ),
          MappingCache(Directory(p.join(support.path, 'live-subtitle-sync', 'mappings'))),
        );
      }().catchError((Object error, StackTrace stack) {
        _resources = null;
        Error.throwWithStackTrace(error, stack);
      });

  /// Invalidates pending writes as well as files. Active sessions observe the
  /// cache generation on their next tick and discard restored/learned maps.
  static Future<bool> clearMappingCache() async => (await _prepareResources()).mappings.clear();

  static Future<void> deleteSpeechModel() async => (await _prepareResources()).models.delete(preferredModel);

  // The guarded Windows runtime recognizes the same fixture in 2.66 s with
  // base.en versus 14.27 s with Q5_1 (DTW enabled). Prefer the larger model
  // there; macOS keeps the smaller model validated on Apple Silicon.
  static LiveSyncModel get preferredModel =>
      Platform.isWindows ? LiveSyncModel.baseEnglish : LiveSyncModel.quantizedEnglish;

  final PlayerNative player;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _timeline = TimelineTracker();
  final _pcmAvailability = PcmAvailability();
  final _transcriptContext = TranscriptContext();
  final _clock = Stopwatch()..start();
  LiveSyncPhase phase = LiveSyncPhase.off;
  LiveSyncReason? reason;
  ModelProgress? modelProgress;

  /// Transient, dialogue-free failure code for an explicitly run test harness.
  /// Never persisted or sent by the feature.
  String? diagnosticFailure;

  /// Opt-in test instrumentation: counts and timing only, never dialogue/PCM.
  void Function(Map<String, Object?>)? diagnosticObserver;
  bool enabled = false;
  bool _requested = false;
  double? automaticOffset;
  int _generation = 0;
  String? _trackKey;
  int _lastAnalysisMs = -60000;
  final _cadence = AnalysisCadence();
  bool _tickBusy = false;
  Timer? _timer;
  AbortController? _sourceAbort;
  LiveSyncAnalysisWorker? _worker;
  SubtitleIndex? _index;
  Future<void>? _loading;
  Future<void>? _stopping;
  Future<void>? _retiringWorker;
  Future<void>? _restarting;
  int? _continuity;
  _Resources? _shared;
  MappingCacheKey? _cacheKey;
  int _cacheGeneration = 0;

  static bool _english(String? language) =>
      language != null &&
      (language.toLowerCase() == 'eng' || language.toLowerCase().split(RegExp('[-_]')).first == 'en');

  void _state(LiveSyncPhase value, [LiveSyncReason? why]) {
    phase = value;
    reason = why;
    notifyListeners();
  }

  Future<void> enable() async {
    _requested = true;
    await _stopping;
    if (enabled || !_requested) return;
    enabled = true;
    final generation = ++_generation;
    _loading = _start(generation);
    await _loading;
    _loading = null;
  }

  Future<void> _restartForTracks() => _restarting ??= () async {
    // Invalidate immediately and wait for the previous native owner to join.
    // Read the latest tracks only after teardown, so rapid selections coalesce.
    await _stopSession();
    if (_requested) await enable();
  }().whenComplete(() => _restarting = null);

  Future<void> _start(int generation) async {
    bool current() => enabled && generation == _generation;
    try {
      final paths = LiveSyncRuntimePaths.bundled();
      if (paths == null) {
        _state(LiveSyncPhase.unsupported, LiveSyncReason.platform);
        return;
      }
      if (player.audioPassthroughActive) {
        _state(LiveSyncPhase.unsupported, LiveSyncReason.passthrough);
        return;
      }
      final selection = player.state.track;
      final subtitle = selection.subtitle;
      _trackKey = '${selection.audio?.id}|${subtitle?.id}';
      if (!_english(selection.audio?.language) || !_english(subtitle?.language)) {
        _state(LiveSyncPhase.unsupported, LiveSyncReason.englishTracks);
        return;
      }
      final provider = LiveSyncPlayerAttachment.subtitleProviders[player];
      final external = subtitle?.isExternal == true && subtitle?.uri != null && subtitle?.isContainer != true;
      if (subtitle == null || (!external && provider == null)) {
        _state(LiveSyncPhase.unsupported, LiveSyncReason.externalSrt);
        return;
      }
      _state(LiveSyncPhase.loadingSubtitles);
      final resources = _shared = await _prepareResources();
      if (!current()) return;
      final abort = _sourceAbort = AbortController();
      final startupClock = Stopwatch()..start();
      var subtitlesReady = false;
      void ensureCurrent() {
        if (!current() || abort.isAborted) throw const ModelException(ModelFailure.cancelled);
      }

      final (index, worker) = await prepareLiveSyncInputs(
        cancelPending: () {
          abort.abort();
          resources.models.cancel(preferredModel);
        },
        closeCapture: (worker) => worker.close(),
        loadSubtitles: () async {
          final document = external
              ? await SubtitleSourceLoader(
                  client: resources.transport.inner,
                ).load(subtitle, headers: player.liveSubtitleHeaders, abort: abort)
              : await provider!(subtitle, resources.transport.inner, abort);
          ensureCurrent();
          if (document == null) throw const SubtitleSourceException(SubtitleSourceFailure.unsupported);
          final index = await compute((bytes) => SubtitleIndex(const SubtitleParser().parse(bytes)), document.bytes);
          ensureCurrent();
          _timeline.clear();
          _cacheKey = null;
          _cacheGeneration = resources.mappings.generation;
          final identity = await LiveSyncPlayerAttachment.mediaIdentities[player]?.call();
          ensureCurrent();
          final audio = selection.audio;
          final key = identity != null && audio != null
              ? MappingCacheKey.create(identity, audio, document.contentHash)
              : null;
          if (key != null) {
            final restored = await resources.mappings.read(key, index);
            ensureCurrent();
            if (_cacheGeneration == resources.mappings.generation) {
              _cacheKey = key;
              if (restored != null) _timeline.restore(restored);
            }
          }
          subtitlesReady = true;
          diagnosticObserver?.call({
            'startupSubtitlesMs': startupClock.elapsedMilliseconds,
            'mappingCacheEligible': _cacheKey != null,
            'restoredSegments': _timeline.map.segments.length,
          });
          return index;
        },
        openCapture: () async {
          final lease = await resources.models.acquire(
            preferredModel,
            onProgress: (progress) {
              if (current()) {
                modelProgress = progress;
                _state(LiveSyncPhase.downloading);
              }
            },
          );
          if (!current() || abort.isAborted) {
            lease.release();
            throw const ModelException(ModelFailure.cancelled);
          }
          final worker = await LiveSyncAnalysisWorker.start(
            playerChannel: player.methodChannel,
            lease: lease,
            captureLibrary: paths.capture,
            inferenceLibrary: paths.inference,
            acceleratedInferenceLibrary: paths.acceleratedInference,
            generation: generation,
          );
          if (!current() || abort.isAborted) {
            await worker.close();
            throw const ModelException(ModelFailure.cancelled);
          }
          diagnosticObserver?.call({
            'startupCaptureMs': startupClock.elapsedMilliseconds,
            'captureReadyBeforeSubtitles': !subtitlesReady,
          });
          if (!subtitlesReady) _state(LiveSyncPhase.loadingSubtitles);
          return worker;
        },
      );
      if (!current()) {
        await worker.close();
        return;
      }
      _index = index;
      _worker = worker;
      _continuity = null;
      _pcmAvailability.clear();
      _transcriptContext.clear();
      _cadence.clear();
      _lastAnalysisMs = -90000;
      // Own the timer before awaiting player properties. A seek may supersede
      // this startup generation while keeping the prepared session active.
      // Register before notifying listeners as a synchronous disable must also
      // be able to cancel the timer immediately.
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => unawaited(_tick()));
      _state(LiveSyncPhase.analyzing);
      if (!current()) return;
      if (diagnosticObserver != null) {
        final status = await worker.status();
        if (!current()) return;
        diagnosticObserver?.call({
          'startupReadyMs': startupClock.elapsedMilliseconds,
          'startupBufferedSamples': status.samples,
        });
      }
      diagnosticObserver?.call({'inferenceBackend': worker.inferenceBackend});
      final position = double.tryParse(await player.getProperty('time-pos') ?? '');
      if (!current()) return;
      if (position != null) await _applyCorrection(position, generation);
    } on SubtitleSourceException catch (error) {
      if (current()) {
        _state(
          LiveSyncPhase.unsupported,
          error.reason == SubtitleSourceFailure.unsupported ? LiveSyncReason.externalSrt : LiveSyncReason.source,
        );
      }
    } on SubtitleParseException {
      if (current()) _state(LiveSyncPhase.unsupported, LiveSyncReason.externalSrt);
    } on ModelException {
      if (current()) _state(LiveSyncPhase.unable, LiveSyncReason.model);
    } catch (_) {
      if (current()) _state(LiveSyncPhase.unable, LiveSyncReason.nativeRuntime);
    }
  }

  Future<void> _tick() async {
    final worker = _worker;
    final index = _index;
    if (_tickBusy || !enabled || worker == null || index == null) return;
    _tickBusy = true;
    final generation = _generation;
    try {
      final mappings = _shared?.mappings;
      if (mappings != null && _cacheGeneration != mappings.generation) {
        _cacheGeneration = mappings.generation;
        _cacheKey = null;
        _timeline.clear();
        _transcriptContext.clear();
        _cadence.clear();
        _lastAnalysisMs = -90000;
      }
      final status = await worker.status();
      if (!enabled || generation != _generation) return;
      if (player.audioPassthroughActive || status.state == 3) {
        await _suspend(
          generation,
          LiveSyncPhase.unsupported,
          player.audioPassthroughActive ? LiveSyncReason.passthrough : LiveSyncReason.surround,
        );
        return;
      }
      if (status.state == 4) {
        await disable();
        return;
      }
      if (_pcmAvailability.expired(
        nowMs: _clock.elapsedMilliseconds,
        samples: status.samples,
        playing: player.state.playing,
        buffering: player.state.buffering,
      )) {
        diagnosticFailure = 'noPcm';
        await _suspend(generation, LiveSyncPhase.unable, LiveSyncReason.nativeRuntime);
        return;
      }
      if (_continuity != null && status.continuity != _continuity) {
        // Overflow, decoder resets and dropped blocks invalidate the evidence
        // as well as the inference. Do not combine anchors across a PCM gap.
        _timeline.discontinuity();
        _transcriptContext.clear();
        _cadence.clear();
        _lastAnalysisMs = -60000;
        if (automaticOffset != null) {
          automaticOffset = null;
          await player.setLiveSubtitleOffset(0);
          if (!enabled || generation != _generation) return;
        }
        await player.setLiveSubtitleSuppressed(false);
        if (!enabled || generation != _generation) return;
        _state(LiveSyncPhase.resyncing);
      }
      _continuity = status.continuity;
      final transcript = await worker.takeResult();
      if (!enabled || generation != _generation) return;
      if (transcript != null && transcript.generation == generation && transcript.continuity == _continuity) {
        final context = _transcriptContext.add(transcript);
        final matchingClock = diagnosticObserver == null ? null : (Stopwatch()..start());
        final evidence = await compute((data) {
          final (NativeTranscript transcript, NativeTranscript? context, SubtitleIndex index) = data;
          return matchTranscriptEvidence(transcript, index, context: context);
        }, (transcript, context, index));
        final anchors = evidence.anchors;
        if (!enabled || generation != _generation) return;
        diagnosticObserver?.call({
          'attempt': _cadence.attempts,
          'generation': generation,
          'continuity': transcript.continuity,
          'inferenceSeconds': transcript.elapsed,
          if (matchingClock != null) 'matchingMs': matchingClock.elapsedMilliseconds,
          'windowStart': transcript.windowStart,
          'windowEnd': transcript.windowEnd,
          'validPrefixOnly': transcript.validPrefixOnly,
          'match': evidence.match.status.name,
          'similarity': evidence.match.passage?.similarity,
          'competitor': evidence.match.runnerUpSimilarity,
          'contextWindows': evidence.windowCount,
          'segmentedMatch': evidence.segmented,
          'anchors': anchors.map((anchor) => {'cue': anchor.cue, 'offset': anchor.offset}).toList(),
        });
        // A wider prompt retry can recover cue beginnings when a recognized
        // passage lacks enough independent timing anchors. Matching and
        // confirmation thresholds remain unchanged.
        final previousMap = _timeline.map;
        final learnedRegion = _timeline.observe(anchors);
        final key = _cacheKey;
        if (key != null && mappings != null && !identical(previousMap, _timeline.map)) {
          unawaited(mappings.write(key, _timeline.map, generation: _cacheGeneration));
        }
        _cadence.evidence(
          recognizedPassage: evidence.match.status == TranscriptMatchStatus.matched,
          learned: learnedRegion,
        );
        if (learnedRegion) {
          final learned = _timeline.map.segments.last;
          diagnosticObserver?.call({
            'learnedMediaStart': learned.mediaStart,
            'learnedMediaEnd': learned.mediaEnd,
            'learnedSlope': learned.slope,
            'learnedSegments': _timeline.map.segments.length,
          });
        }
        if (_cadence.attempts >= 5 && automaticOffset == null) {
          _state(LiveSyncPhase.unable, LiveSyncReason.noMatch);
        }
      }
      // Query the native media clock: cached UI positions can be throttled or
      // lag behind a seek. Affine correction changes with playback position.
      final position = double.tryParse(await player.getProperty('time-pos') ?? '');
      if (!enabled || generation != _generation) return;
      final established = position != null && await _applyCorrection(position, generation);
      if (!player.state.playing || player.state.buffering || status.samples < 128000) return;
      final activity = await worker.activity();
      if (!enabled || generation != _generation) return;
      final validActivity =
          activity != null &&
          activity.generation == generation &&
          activity.continuity == _continuity &&
          activity.observedSeconds >= 4;
      bool? voicePresent;
      var mismatch = false;
      if (validActivity) {
        voicePresent = activity.voiceSeconds >= 0.4;
        final start = _timeline.correctionAt(activity.start).position.subtitleTime;
        final end = _timeline.correctionAt(activity.end).position.subtitleTime;
        if (start != null && end != null && end > start) {
          final expectedFraction = index.dialogueSecondsBetween(start, end) / (end - start);
          final actualFraction = activity.voiceSeconds / activity.observedSeconds;
          // Wide tolerances: subtitle display durations are only a rough proxy
          // for speech. Disagreement requests ASR; it never invalidates a map.
          mismatch =
              expectedFraction < 0.05 && actualFraction > 0.35 || expectedFraction > 0.5 && actualFraction < 0.02;
        }
      }
      // Collect spaced confirmation windows before slowing to steady-state
      // checks, so a cadence difference can actually accumulate six anchors.
      final intervalMs = _cadence.intervalMs(
        synced: phase == LiveSyncPhase.synced,
        established: established,
        voicePresent: voicePresent,
        timingMismatch: mismatch,
      );
      if (_clock.elapsedMilliseconds - _lastAnalysisMs >= intervalMs &&
          await worker.submitRecent(seconds: _cadence.windowSeconds)) {
        _lastAnalysisMs = _clock.elapsedMilliseconds;
        _cadence.submitted();
        diagnosticObserver?.call({
          'analysisRequest': _cadence.attempts,
          'generation': generation,
          'continuity': _continuity,
          'activityVoicePresent': voicePresent,
          'activityTimingMismatch': mismatch,
          'analysisIntervalMs': intervalMs,
          'analysisWindowSeconds': _cadence.windowSeconds,
        });
      }
    } catch (error) {
      if (enabled &&
          generation == _generation &&
          error is NativeSyncException &&
          (error.reason == NativeSyncFailure.inferenceUnavailable || error.reason == NativeSyncFailure.invalidOutput)) {
        _cadence.rejectedInference();
      }
      diagnosticFailure = error is NativeSyncException ? error.reason.name : error.runtimeType.toString();
      if (enabled && generation == _generation) {
        diagnosticObserver?.call({
          'attempt': _cadence.attempts,
          'failure': diagnosticFailure,
          if (error is NativeSyncException && error.nativeStatus != null) 'nativeStatus': error.nativeStatus,
        });
      }
      if (enabled && generation == _generation) {
        final rejectedInference =
            error is NativeSyncException &&
            (error.reason == NativeSyncFailure.inferenceUnavailable || error.reason == NativeSyncFailure.invalidOutput);
        if (!rejectedInference) {
          try {
            // A failed capture/control path can stop clock updates. Its mask
            // must not keep hiding dialogue after playback has left the gap.
            await _clearAutomaticPresentation(generation: generation);
          } catch (_) {
            // Preserve the failure state; explicit disable may retry cleanup.
          }
        }
        if (enabled && generation == _generation) _state(LiveSyncPhase.unable, LiveSyncReason.nativeRuntime);
      }
    } finally {
      _tickBusy = false;
    }
  }

  Future<bool> _applyCorrection(double position, int generation) async {
    final audioDelay = double.tryParse(await player.getProperty('audio-delay') ?? '');
    if (!enabled || generation != _generation || audioDelay == null) return false;
    final correction = _timeline.correctionAt(position, audioDelay: audioDelay);
    final offset = correction.position.automaticDelay;
    if (offset == null) {
      final suppressed = correction.position.kind == TimelineRegionKind.videoOnly;
      if (suppressed) {
        // Mask first, before clearing a previous delay could expose future
        // dialogue inside an explicitly confirmed absence of correspondence.
        await player.setLiveSubtitleSuppressed(true);
        if (!enabled || generation != _generation) return false;
      }
      if (automaticOffset != null) {
        await player.setLiveSubtitleOffset(0);
        if (!enabled || generation != _generation) return false;
        automaticOffset = null;
        _state(LiveSyncPhase.resyncing);
      }
      if (!suppressed) {
        await player.setLiveSubtitleSuppressed(false);
        if (!enabled || generation != _generation) return false;
      } else if (phase != LiveSyncPhase.resyncing) {
        _state(LiveSyncPhase.resyncing);
      }
      return false;
    }
    if (automaticOffset == null || (offset - automaticOffset!).abs() >= 0.01) {
      await player.setLiveSubtitleOffset(offset);
      if (!enabled || generation != _generation) return false;
      automaticOffset = offset;
    }
    // Apply the new mapping before revealing subtitles when leaving a gap.
    await player.setLiveSubtitleSuppressed(false);
    if (!enabled || generation != _generation) return false;
    if (phase != LiveSyncPhase.synced) _state(LiveSyncPhase.synced);
    return correction.established;
  }

  Future<void> _reset({Duration? target}) async {
    if (!enabled || _worker == null) return;
    final generation = ++_generation;
    _timeline.discontinuity();
    _transcriptContext.clear();
    _continuity = null;
    _pcmAvailability.clear();
    _cadence.clear();
    automaticOffset = null;
    _lastAnalysisMs = -60000;
    try {
      await _worker!.reset(generation);
      await player.setLiveSubtitleOffset(0);
      if (enabled && generation == _generation) {
        _state(LiveSyncPhase.resyncing);
        if (target != null) {
          await _applyCorrection(target.inMicroseconds / 1e6, generation);
        } else {
          await player.setLiveSubtitleSuppressed(false);
        }
      }
    } catch (_) {
      if (enabled && generation == _generation) {
        try {
          await player.setLiveSubtitleSuppressed(false);
        } catch (_) {
          // Keep the error state; the next tick or explicit stop can retry.
        }
        if (enabled && generation == _generation) _state(LiveSyncPhase.unable, LiveSyncReason.nativeRuntime);
      }
    }
  }

  Future<void> disable() {
    _requested = false;
    return _stopSession();
  }

  Future<void> _suspend(int generation, LiveSyncPhase phase, LiveSyncReason reason) async {
    _timer?.cancel();
    _timer = null;
    final worker = _worker;
    _worker = null;
    try {
      if (worker != null) {
        final retirement = worker.close();
        _retiringWorker = retirement;
        try {
          await retirement;
        } finally {
          if (identical(_retiringWorker, retirement)) _retiringWorker = null;
        }
      }
    } finally {
      if (enabled && generation == _generation) {
        await _clearAutomaticPresentation(generation: generation);
        if (enabled && generation == _generation) {
          _timeline.clear();
          _transcriptContext.clear();
          _state(phase, reason);
        }
      }
    }
  }

  Future<void> _stopSession() => _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _clearAutomaticPresentation({int? generation}) async {
    bool current() => generation == null || (enabled && generation == _generation);
    try {
      await player.setLiveSubtitleOffset(0);
      if (current()) automaticOffset = null;
    } finally {
      // A failed delay write must not strand a temporary visibility mask.
      // A superseded tick must not release a newer generation's mask either.
      if (current()) await player.setLiveSubtitleSuppressed(false);
    }
  }

  Future<void> _stop() async {
    enabled = false;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _sourceAbort?.abort();
    _shared?.models.cancel(preferredModel);
    try {
      await _loading;
      final worker = _worker;
      _worker = null;
      await worker?.close();
      await _retiringWorker;
    } finally {
      var presentationRestored = false;
      try {
        await _clearAutomaticPresentation();
        presentationRestored = true;
      } finally {
        _index = null;
        _cacheKey = null;
        _timeline.clear();
        _transcriptContext.clear();
        _state(
          presentationRestored ? LiveSyncPhase.off : LiveSyncPhase.unable,
          presentationRestored ? null : LiveSyncReason.nativeRuntime,
        );
      }
    }
  }
}
