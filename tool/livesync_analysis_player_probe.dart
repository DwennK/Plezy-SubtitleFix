/// Exercises the production LiveSync controller and control with real film
/// audio from the designated calibration partition. This is a test entrypoint.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:plezy/features/live_subtitle_sync/control.dart';
import 'package:plezy/features/live_subtitle_sync/controller.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.getInstance();
  await windowManager.ensureInitialized();
  await windowManager.setSize(const Size(1440, 900));
  await windowManager.setTitle('LiveSync calibration validation');
  runApp(MaterialApp(theme: ThemeData.dark(), home: const _Probe()));
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final player = Player() as PlayerNative;
  LiveSubtitleSyncController? controller;
  bool videoReady = false;
  String status = 'Preparing calibration fixture';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void check(bool value, String phase) {
    if (!value) throw StateError(phase);
  }

  Future<void> _run() async {
    const directory = String.fromEnvironment('LIVESYNC_ANALYSIS_FIXTURE_DIR');
    final output = File('$directory/result.json');
    final diagnostics = <Map<String, Object?>>[];
    HttpServer? subtitleServer;
    const sourceDelayMs = int.fromEnvironment('LIVESYNC_SUBTITLE_LOAD_DELAY_MS');
    var delayNextSourceRead = false;
    var delayedSourceReads = 0;
    try {
      check(directory.isNotEmpty, 'fixture');
      check(sourceDelayMs == 0 || sourceDelayMs == 15000, 'source-delay-fixture');
      var subtitleLocation = '$directory/fixture.srt';
      if (sourceDelayMs > 0) {
        subtitleServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        subtitleLocation = 'http://127.0.0.1:${subtitleServer.port}/fixture.srt';
        final bytes = await File('$directory/fixture.srt').readAsBytes();
        subtitleServer.listen((request) async {
          if (request.uri.path != '/fixture.srt') {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            if (delayNextSourceRead) {
              delayNextSourceRead = false;
              delayedSourceReads++;
              await Future<void>.delayed(const Duration(milliseconds: sourceDelayMs));
            }
            request.response.headers.contentType = ContentType('application', 'x-subrip');
            request.response.add(bytes);
          }
          await request.response.close();
        });
      }
      final provenance = jsonDecode(await File('$directory/fixture-provenance.json').readAsString()) as Map;
      final expectedOffset = (provenance['expectedOffsetSeconds'] as num).toDouble();
      final introSilence = (provenance['introSilenceSeconds'] as num?)?.toInt() ?? 0;
      check(
        expectedOffset.isFinite && expectedOffset.abs() <= 600 && (introSilence == 0 || introSilence == 90),
        'fixture-metadata',
      );
      final acquisitionLimit = Duration(seconds: 75 + introSilence);
      final spec = LiveSubtitleSyncController.preferredModel;
      final cache = Directory(p.join((await getApplicationSupportDirectory()).path, 'live-subtitle-sync', 'models'));
      await cache.create(recursive: true);
      final model = File(p.join(cache.path, '${spec.sha256}.bin'));
      if (!await model.exists()) {
        final provided = File('$directory/model.bin');
        check(
          await provided.length() == spec.bytes &&
              (await crypto.sha256.bind(provided.openRead()).first).toString() == spec.sha256,
          'model-integrity',
        );
        await provided.copy(model.path);
      }
      if (Platform.isWindows) {
        await player.setProperty('ao-pcm-file', 'NUL');
        await player.setProperty('ao-pcm-waveheader', 'no');
        await player.setProperty('ao', 'pcm');
        await player.setProperty('gpu-api', 'd3d11');
        await player.setProperty('gpu-context', 'd3d11');
        await player.setProperty('d3d11-warp', 'yes');
      } else {
        await player.setProperty('ao', 'null');
      }
      await player.configureSubtitleFonts();
      if (mounted) setState(() => videoReady = true);
      await WidgetsBinding.instance.endOfFrame;
      final tracksReady = player.streams.tracks.firstWhere(
        (tracks) =>
            tracks.audio.any((track) => track.language == 'eng') && tracks.subtitle.any((track) => track.isExternal),
      );
      await player.open(
        Media('$directory/fixture.mkv'),
        play: false,
        externalSubtitles: [SubtitleTrack.uri(subtitleLocation, language: 'eng', codec: 'srt')],
      );
      final tracks = await tracksReady.timeout(const Duration(seconds: 15));
      final audio = tracks.audio.firstWhere((track) => track.language == 'eng');
      final subtitle = tracks.subtitle.firstWhere((track) => track.isExternal);
      // A property command acknowledgement precedes the selected-track event,
      // especially on Windows. Start only once the production state confirms
      // both identities and their metadata.
      await player.selectAudioTrack(audio);
      await player.selectSubtitleTrack(subtitle);
      if (player.state.track.audio?.id != audio.id || player.state.track.subtitle?.id != subtitle.id) {
        await player.streams.track
            .firstWhere((selection) => selection.audio?.id == audio.id && selection.subtitle?.id == subtitle.id)
            .timeout(const Duration(seconds: 10));
      }
      diagnostics.add({
        'selectedAudioLanguage': player.state.track.audio?.language,
        'selectedSubtitleLanguage': player.state.track.subtitle?.language,
        'subtitleExternal': player.state.track.subtitle?.isExternal,
        'subtitleSourceMatchesFixture':
            p.normalize(player.state.track.subtitle?.uri ?? '') == p.normalize(subtitleLocation),
      });
      await player.setProperty('sub-delay', '0.125');
      final sync = controller = LiveSubtitleSyncController.forPlayer(player);
      sync.diagnosticObserver = diagnostics.add;
      if (mounted) {
        setState(() => status = 'Sintel calibration; expected offset $expectedOffset s; added silence $introSilence s');
      }
      await player.play();
      delayNextSourceRead = sourceDelayMs > 0;
      final started = Stopwatch()..start();
      await sync.enable();
      if (sourceDelayMs > 0) {
        final capture = diagnostics.firstWhere((event) => event.containsKey('startupCaptureMs'));
        final source = diagnostics.firstWhere((event) => event.containsKey('startupSubtitlesMs'));
        final ready = diagnostics.firstWhere((event) => event.containsKey('startupBufferedSamples'));
        check(delayedSourceReads == 1, 'source-delay-not-exercised');
        check(capture['captureReadyBeforeSubtitles'] == true, 'capture-did-not-overlap-source');
        check((source['startupSubtitlesMs'] as int) >= sourceDelayMs, 'incomplete-subtitles-used');
        check((capture['startupCaptureMs'] as int) < (source['startupSubtitlesMs'] as int), 'capture-started-late');
        check((ready['startupBufferedSamples'] as int) >= 128000, 'capture-did-not-fill-during-source-load');
      }
      while (sync.phase != LiveSyncPhase.synced) {
        await output.writeAsString(
          jsonEncode({
            'phase': sync.phase.name,
            'reason': sync.reason?.name,
            'failureCode': sync.diagnosticFailure,
            'analyses': diagnostics,
            'positionMs': player.currentPosition.inMilliseconds,
            'elapsedMs': started.elapsedMilliseconds,
          }),
        );
        check(started.elapsed < acquisitionLimit, 'acquisition-timeout');
        check(sync.phase != LiveSyncPhase.unsupported, 'unsupported-${sync.reason?.name}');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final automatic = sync.automaticOffset!;
      const maximumOffsetError = 0.75;
      check((automatic - expectedOffset).abs() < maximumOffsetError, 'incorrect-offset');
      final nativeDelay = double.parse((await player.getProperty('sub-delay'))!);
      check((nativeDelay - automatic - 0.125).abs() < 0.0001, 'native-delay');
      final report = <String, Object>{
        'kind': 'actual-plezy-production-controller-calibration',
        'subtitleLoadDelayMs': sourceDelayMs,
        'startupDiagnostics': diagnostics.where((event) => event.keys.any((key) => key.startsWith('startup'))).toList(),
        'captureDuringSubtitleLoadValidated': sourceDelayMs > 0,
        'platform': Platform.operatingSystem,
        'inferenceBackend':
            diagnostics.firstWhere((entry) => entry.containsKey('inferenceBackend'))['inferenceBackend']! as String,
        'expectedOffset': expectedOffset,
        'absoluteOffsetError': (automatic - expectedOffset).abs(),
        'maximumOffsetError': maximumOffsetError,
        'modelId': spec.id,
        'modelSha256': spec.sha256,
        'fixtureCase': provenance['case'] ?? 'calibration',
        'introSilenceSeconds': introSilence,
        'actualOffset': automatic,
        'reference': 'authored Sintel SRT, not precise acoustic-onset ground truth',
        'acquisitionMs': started.elapsedMilliseconds,
        'nativeDelay': nativeDelay,
        'audioPartitionSeconds': provenance['partition'] as List,
        'audioOutput': Platform.isWindows ? 'pcm-to-NUL' : 'null',
        'audiblePlaybackValidated': false,
        'pcmOrTranscriptPersisted': false,
      };
      await output.writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
      if (mounted) setState(() => status = 'Automatic correction applied — inspecting native subtitles');
      await Future<void>.delayed(const Duration(seconds: 12));
      await player.pause();
      await player.setProperty('sub-delay', '-0.25');
      Future<double> checkComposition(String stage, {double audioDelay = 0, double? fixedAutomatic}) async {
        final deadline = Stopwatch()..start();
        while (true) {
          final before = sync.automaticOffset;
          final native = double.parse((await player.getProperty('sub-delay'))!);
          final after = sync.automaticOffset;
          // A confirmation may refine the first lock while the film plays.
          // Observe a coherent current value, retaining the strict manual
          // composition and fixture accuracy checks. A lost lock still fails.
          if (before != null && before == after && (native - before + 0.25).abs() < 0.0001) {
            check((before - expectedOffset - audioDelay).abs() < maximumOffsetError, '$stage-accuracy');
            if (fixedAutomatic != null) {
              check((before - fixedAutomatic).abs() < 0.0001, '$stage-mapping');
            }
            return before;
          }
          check(deadline.elapsed < const Duration(seconds: 2), stage);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      report['postConfirmationOffset'] = await checkComposition('manual-during');
      final learned = diagnostics.lastWhere((entry) => entry.containsKey('learnedMediaStart'));
      final learnedStart = (learned['learnedMediaStart'] as num).toDouble();
      final learnedEnd = (learned['learnedMediaEnd'] as num).toDouble();
      check(learnedEnd - learnedStart >= 3, 'learned-domain');
      final knownPosition = (learnedStart + learnedEnd) / 2;
      final unknownPosition = 73.0 + introSilence;
      check(unknownPosition > learnedEnd + 1, 'unknown-test-domain');
      Future<void> seekAndWait(double seconds, bool known) async {
        await player.seek(Duration(microseconds: (seconds * 1e6).round()));
        final deadline = Stopwatch()..start();
        while (true) {
          final actual = double.tryParse(await player.getProperty('time-pos') ?? '');
          final ready = known ? sync.phase == LiveSyncPhase.synced : sync.automaticOffset == null;
          if (ready && actual != null && (actual - seconds).abs() < 0.5) break;
          check(deadline.elapsed < const Duration(seconds: 8), known ? 'known-seek-timeout' : 'unknown-seek-timeout');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // Let the next controller tick observe the native landing as well.
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }

      // Land in the learned domain first. This cancels in-flight recognition
      // and establishes the exact reference for the subsequent round trip.
      // The initial lock is not that reference: it may have been refined.
      await seekAndWait(knownPosition, true);
      final knownAutomatic = await checkComposition('known-before-seek');
      await seekAndWait(unknownPosition, false);
      check(sync.automaticOffset == null, 'unknown-seek-retained-prediction');
      check((double.parse((await player.getProperty('sub-delay'))!) + 0.25).abs() < 0.0001, 'unknown-seek-manual');
      await seekAndWait(knownPosition, true);
      await checkComposition('known-seek-manual', fixedAutomatic: knownAutomatic);
      report.addAll({'knownRegionRestoredAfterSeek': true, 'unknownSeekClearsAutomaticOnly': true});
      for (final audioDelay in [-0.5, 0.5]) {
        await player.setProperty('audio-delay', audioDelay.toString());
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await checkComposition(
          'audio-and-manual-subtitle-delay',
          audioDelay: audioDelay,
          fixedAutomatic: knownAutomatic + audioDelay,
        );
      }
      await sync.disable();
      check((double.parse((await player.getProperty('sub-delay'))!) + 0.25).abs() < 0.0001, 'manual-after');
      check(await player.getProperty('livesync-enabled') == 'no', 'capture-after');
      check(double.parse((await player.getProperty('audio-delay'))!) == 0.5, 'audio-delay-after');
      report['audioDelayCompositionAndPreservation'] = true;
      final cacheDiagnosticStart = diagnostics.length;
      final restoring = Stopwatch()..start();
      await sync.enable();
      final cacheEvents = diagnostics
          .skip(cacheDiagnosticStart)
          .where((event) => event.containsKey('restoredSegments'));
      check(cacheEvents.isNotEmpty && (cacheEvents.last['restoredSegments'] as int) > 0, 'cache-not-restored');
      await checkComposition('cache-known-region', audioDelay: 0.5, fixedAutomatic: knownAutomatic + 0.5);
      report['cacheRestoreMs'] = restoring.elapsedMilliseconds;
      await seekAndWait(unknownPosition, false);
      check((double.parse((await player.getProperty('sub-delay'))!) + 0.25).abs() < 0.0001, 'cache-unknown-manual');
      await seekAndWait(knownPosition, true);
      await checkComposition('cache-known-after-seek', audioDelay: 0.5, fixedAutomatic: knownAutomatic + 0.5);
      await sync.disable();
      check((double.parse((await player.getProperty('sub-delay'))!) + 0.25).abs() < 0.0001, 'cache-manual-after');
      check(await player.getProperty('livesync-enabled') == 'no', 'cache-capture-after');
      report['persistentCacheKnownAndUnknownRegions'] = true;
      report.addAll({'manualDelayDuringAndAfter': true, 'tapDisabledOnClose': true, 'passed': true});
      await output.writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
      if (mounted) setState(() => status = 'PASS — automatic offset, manual adjustment and disable verified');
    } catch (error) {
      await controller?.disable();
      await output.writeAsString(
        jsonEncode({
          'passed': false,
          'phase': error is StateError ? error.message : 'native-probe-error',
          'analyses': diagnostics,
          'failureCode': controller?.diagnosticFailure,
        }),
      );
      if (mounted) setState(() => status = 'Calibration check failed; inspect result.json');
    } finally {
      await subtitleServer?.close(force: true);
    }
  }

  @override
  void dispose() {
    unawaited(player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Expanded(child: videoReady ? Video(player: player) : const SizedBox.shrink()),
        Padding(padding: const EdgeInsets.all(12), child: Text(status)),
        if (controller != null) LiveSubtitleSyncControl(player: player),
      ],
    ),
  );
}
