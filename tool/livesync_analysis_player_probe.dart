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
import 'package:plezy/features/live_subtitle_sync/model_manager.dart';
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
    try {
      check(directory.isNotEmpty, 'fixture');
      final spec = LiveSyncModel.quantizedEnglish;
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
        externalSubtitles: [SubtitleTrack.uri('$directory/fixture.srt', language: 'eng', codec: 'srt')],
      );
      final tracks = await tracksReady.timeout(const Duration(seconds: 15));
      await player.selectAudioTrack(tracks.audio.firstWhere((track) => track.language == 'eng'));
      await player.selectSubtitleTrack(tracks.subtitle.firstWhere((track) => track.isExternal));
      await player.setProperty('sub-delay', '0.125');
      final sync = controller = LiveSubtitleSyncController.forPlayer(player);
      final diagnostics = <Map<String, Object?>>[];
      sync.diagnosticObserver = diagnostics.add;
      if (mounted) setState(() => status = 'Sintel calibration audio 100–175 s; expected offset −100 s');
      await player.play();
      final started = Stopwatch()..start();
      await sync.enable();
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
        check(started.elapsed < const Duration(seconds: 75), 'acquisition-timeout');
        check(sync.phase != LiveSyncPhase.unsupported, 'unsupported-${sync.reason?.name}');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final automatic = sync.automaticOffset!;
      check((automatic + 100).abs() < 1.5, 'incorrect-offset');
      final nativeDelay = double.parse((await player.getProperty('sub-delay'))!);
      check((nativeDelay - automatic - 0.125).abs() < 0.0001, 'native-delay');
      final report = <String, Object>{
        'kind': 'actual-plezy-production-controller-calibration',
        'platform': Platform.operatingSystem,
        'expectedOffset': -100,
        'actualOffset': automatic,
        'reference': 'authored Sintel SRT, not precise acoustic-onset ground truth',
        'acquisitionMs': started.elapsedMilliseconds,
        'nativeDelay': nativeDelay,
        'audioPartitionSeconds': [100, 175],
        'audioOutput': Platform.isWindows ? 'pcm-to-NUL' : 'null',
        'audiblePlaybackValidated': false,
        'pcmOrTranscriptPersisted': false,
      };
      await output.writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
      if (mounted) setState(() => status = 'Automatic correction applied — inspecting native subtitles');
      await Future<void>.delayed(const Duration(seconds: 12));
      await player.pause();
      await player.setProperty('sub-delay', '-0.25');
      check(
        (double.parse((await player.getProperty('sub-delay'))!) - automatic + 0.25).abs() < 0.0001,
        'manual-during',
      );
      await sync.disable();
      check((double.parse((await player.getProperty('sub-delay'))!) + 0.25).abs() < 0.0001, 'manual-after');
      check(await player.getProperty('livesync-enabled') == 'no', 'capture-after');
      report.addAll({'manualDelayDuringAndAfter': true, 'tapDisabledOnClose': true, 'passed': true});
      await output.writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
      if (mounted) setState(() => status = 'PASS — automatic offset, manual adjustment and disable verified');
    } catch (error) {
      await controller?.disable();
      await output.writeAsString(
        jsonEncode({'passed': false, 'phase': error is StateError ? error.message : 'native-probe-error'}),
      );
      if (mounted) setState(() => status = 'Calibration check failed; inspect result.json');
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
