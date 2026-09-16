import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../mpv/player/player_native.dart';
import '../../utils/media_server_http_client.dart';
import 'analysis_worker.dart';
import 'model_manager.dart';
import 'native_bindings.dart';
import 'player_attachment.dart';
import 'runtime_paths.dart';
import 'subtitle_index.dart';
import 'subtitle_parser.dart';
import 'subtitle_source.dart';
import 'temporal_aligner.dart';
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
  _Resources(this.transport, this.models);
  final MediaServerHttpClient transport;
  final LiveSyncModelManager models;
}

class LiveSubtitleSyncController extends ChangeNotifier {
  LiveSubtitleSyncController._(this.player) {
    LiveSyncPlayerAttachment.sessions[player] = LiveSyncPlayerAttachment(disable);
    _subscriptions.add(player.streams.playheadJump.listen((_) => unawaited(_reset())));
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

  static Future<_Resources> _prepareResources() => _resources ??= () async {
    final transport = MediaServerHttpClient();
    final support = await getApplicationSupportDirectory();
    return _Resources(
      transport,
      LiveSyncModelManager(
        directory: Directory(p.join(support.path, 'live-subtitle-sync', 'models')),
        client: transport.inner,
      ),
    );
  }();

  final PlayerNative player;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _estimator = ConstantOffsetEstimator();
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
  int _attempts = 0;
  bool _tickBusy = false;
  Timer? _timer;
  AbortController? _sourceAbort;
  LiveSyncAnalysisWorker? _worker;
  SubtitleIndex? _index;
  Future<void>? _loading;
  Future<void>? _stopping;
  Future<void>? _restarting;
  int? _continuity;
  _Resources? _shared;

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
      final document = external
          ? await SubtitleSourceLoader(
              client: resources.transport.inner,
            ).load(subtitle, headers: player.liveSubtitleHeaders, abort: abort)
          : await provider!(subtitle, resources.transport.inner, abort);
      if (!current()) return;
      if (document == null) {
        _state(LiveSyncPhase.unsupported, LiveSyncReason.externalSrt);
        return;
      }
      _index = await compute((bytes) => SubtitleIndex(const SubtitleParser().parse(bytes)), document.bytes);
      if (!current()) return;
      _state(LiveSyncPhase.downloading);
      final lease = await resources.models.acquire(
        LiveSyncModel.quantizedEnglish,
        onProgress: (progress) {
          if (current()) {
            modelProgress = progress;
            notifyListeners();
          }
        },
      );
      if (!current()) {
        lease.release();
        return;
      }
      final worker = await LiveSyncAnalysisWorker.start(
        playerChannel: player.methodChannel,
        lease: lease,
        captureLibrary: paths.capture,
        inferenceLibrary: paths.inference,
        generation: generation,
      );
      if (!current()) {
        await worker.close();
        return;
      }
      _worker = worker;
      _continuity = null;
      _estimator.clear();
      _attempts = 0;
      _lastAnalysisMs = -60000;
      _state(LiveSyncPhase.analyzing);
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => unawaited(_tick()));
    } on SubtitleSourceException {
      if (current()) _state(LiveSyncPhase.unsupported, LiveSyncReason.source);
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
      final status = await worker.status();
      if (!enabled || generation != _generation) return;
      if (status.state == 3) {
        _timer?.cancel();
        _worker = null;
        await worker.close();
        await player.setLiveSubtitleOffset(0);
        automaticOffset = null;
        _state(LiveSyncPhase.unsupported, LiveSyncReason.surround);
        return;
      }
      if (status.state == 4) {
        await disable();
        return;
      }
      if (_continuity != null && status.continuity != _continuity) {
        // Overflow, decoder resets and dropped blocks invalidate the evidence
        // as well as the inference. Do not combine anchors across a PCM gap.
        _estimator.clear();
        _attempts = 0;
        _lastAnalysisMs = -60000;
        if (automaticOffset != null) {
          automaticOffset = null;
          await player.setLiveSubtitleOffset(0);
          if (!enabled || generation != _generation) return;
        }
        _state(LiveSyncPhase.resyncing);
      }
      _continuity = status.continuity;
      final transcript = await worker.takeResult();
      if (!enabled || generation != _generation) return;
      if (transcript != null && transcript.generation == generation && transcript.continuity == _continuity) {
        final (anchors, matchStatus, similarity, competitor) = await compute((data) {
          final (NativeTranscript transcript, SubtitleIndex index) = data;
          final text = transcript.segments.map((segment) => segment.text).join(' ');
          final result = const TranscriptMatcher().find(text, index);
          final anchors = result.status == TranscriptMatchStatus.matched
              ? const TemporalAligner().anchors(transcript, index, result.passage!)
              : <SubtitleAnchor>[];
          return (anchors, result.status.name, result.passage?.similarity, result.runnerUpSimilarity);
        }, (transcript, index));
        if (!enabled || generation != _generation) return;
        diagnosticObserver?.call({
          'attempt': _attempts,
          'windowStart': transcript.windowStart,
          'windowEnd': transcript.windowEnd,
          'match': matchStatus,
          'similarity': similarity,
          'competitor': competitor,
          'anchors': anchors.map((anchor) => {'cue': anchor.cue, 'offset': anchor.offset}).toList(),
        });
        final offset = _estimator.add(anchors);
        if (offset != null) {
          await player.setLiveSubtitleOffset(offset.abs() < 0.25 ? 0 : offset);
          if (!enabled || generation != _generation) return;
          automaticOffset = offset;
          _state(LiveSyncPhase.synced);
        } else if (_attempts >= 5 && automaticOffset == null) {
          _state(LiveSyncPhase.unable, LiveSyncReason.noMatch);
        }
      }
      if (!player.state.playing || player.state.buffering || status.samples < 128000) return;
      final intervalMs = phase == LiveSyncPhase.synced ? 90000 : (_attempts > 3 ? 30000 : 12000);
      if (_clock.elapsedMilliseconds - _lastAnalysisMs >= intervalMs && await worker.submitRecent()) {
        _lastAnalysisMs = _clock.elapsedMilliseconds;
        _attempts++;
      }
    } catch (error) {
      diagnosticFailure = error is NativeSyncException ? error.reason.name : error.runtimeType.toString();
      if (enabled && generation == _generation) _state(LiveSyncPhase.unable, LiveSyncReason.nativeRuntime);
    } finally {
      _tickBusy = false;
    }
  }

  Future<void> _reset() async {
    if (!enabled || _worker == null) return;
    final generation = ++_generation;
    _estimator.clear();
    _continuity = null;
    _attempts = 0;
    automaticOffset = null;
    _lastAnalysisMs = -60000;
    try {
      await _worker!.reset(generation);
      await player.setLiveSubtitleOffset(0);
      if (enabled && generation == _generation) _state(LiveSyncPhase.resyncing);
    } catch (_) {
      if (enabled) _state(LiveSyncPhase.unable, LiveSyncReason.nativeRuntime);
    }
  }

  Future<void> disable() {
    _requested = false;
    return _stopSession();
  }

  Future<void> _stopSession() => _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    enabled = false;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _sourceAbort?.abort();
    _shared?.models.cancel(LiveSyncModel.quantizedEnglish);
    await _loading;
    final worker = _worker;
    _worker = null;
    await worker?.close();
    await player.setLiveSubtitleOffset(0);
    automaticOffset = null;
    _index = null;
    _estimator.clear();
    _state(LiveSyncPhase.off);
  }
}
