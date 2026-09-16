/// Native feasibility harness using Plezy's actual Player and Video widgets.
/// Not a production entrypoint or an automatic synchronization implementation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized().ensureSemantics();
  runApp(MaterialApp(theme: ThemeData.dark(), home: const _Probe()));
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final player = Player();
  String status = 'Preparing local fixture';
  bool busy = true;
  bool videoReady = false;
  String phase = 'starting';

  Future<void> _checkpoint(String value) async {
    phase = value;
    const directory = String.fromEnvironment('LIVESYNC_RENDERER_AUTOMATION_DIR');
    if (directory.isEmpty) return;
    await Directory(directory).create(recursive: true);
    await File('$directory/preparation.json').writeAsString(jsonEncode({'phase': phase}));
  }

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      await _checkpoint('checking-fixture');
      const directory = String.fromEnvironment('LIVESYNC_FIXTURE_DIR');
      final video = File('$directory/fixture.mkv');
      final subtitles = File('$directory/fixture.srt');
      if (directory.isEmpty || !video.existsSync() || !subtitles.existsSync()) {
        throw StateError('Build with LIVESYNC_FIXTURE_DIR containing fixture.mkv and fixture.srt');
      }
      final track = SubtitleTrack.uri(subtitles.path, language: 'eng', codec: 'srt');
      String canonicalPath(String path) {
        final uri = Uri.tryParse(path);
        final file = uri?.scheme == 'file' ? uri!.toFilePath(windows: Platform.isWindows) : path;
        return Platform.isWindows ? file.replaceAll(r'\', '/').toLowerCase() : file;
      }

      bool isFixtureTrack(SubtitleTrack candidate) =>
          candidate.uri != null && canonicalPath(candidate.uri!) == canonicalPath(subtitles.path);
      if (const String.fromEnvironment('LIVESYNC_RENDERER_AUTOMATION_DIR').isNotEmpty) {
        // Hosted Windows runners may have no physical audio endpoint. This
        // dedicated rendering proof does not claim audible-output validation.
        await _checkpoint('initializing-player');
        if (Platform.isWindows) {
          // Plezy's audio recovery intentionally treats ao=null as a failed
          // device and ends playback. Use the Windows discard device instead;
          // no samples are retained, and audible playback is still untested.
          await player.setProperty('ao-pcm-file', 'NUL').timeout(const Duration(seconds: 20));
          await player.setProperty('ao-pcm-waveheader', 'no');
          await player.setProperty('ao', 'pcm');
          // A hosted runner has no physical GPU. Exercise the actual native
          // D3D11 window with Windows WARP; this is not a hardware GPU proof.
          await player.setProperty('gpu-api', 'd3d11');
          await player.setProperty('gpu-context', 'd3d11');
          await player.setProperty('d3d11-warp', 'yes');
        } else {
          await player.setProperty('ao', 'null').timeout(const Duration(seconds: 20));
        }
      }
      await _checkpoint('configuring-fonts');
      await player.setProperty('volume', '5');
      await player.configureSubtitleFonts();
      // The standalone harness must initialize the native HWND before Video
      // sends its first rect. A rect sent to an absent HWND is a successful
      // no-op upstream, leaving the video at the native 100x100 default.
      if (mounted) setState(() => videoReady = true);
      await WidgetsBinding.instance.endOfFrame;
      final tracksReady = player.streams.tracks
          .firstWhere((tracks) => tracks.subtitle.any(isFixtureTrack))
          .timeout(const Duration(seconds: 20));
      final ready = player.streams.playbackRestart.first.timeout(const Duration(seconds: 20));
      await _checkpoint('opening-media');
      await player.open(
        Media(video.path, start: const Duration(milliseconds: 1500)),
        play: false,
        externalSubtitles: [track],
      );
      await _checkpoint('waiting-playback-restart');
      await ready;
      await _checkpoint('waiting-subtitle-track');
      final available = await tracksReady;
      await player.selectSubtitleTrack(available.subtitle.firstWhere(isFixtureTrack));
      await player.setProperty('sub-delay', '0.125');
      await player.setProperty('sub-pos', '70');
      await player.setProperty('sub-font-size', '44');
      await _describe('Baseline: manual delay 0.125 s');
      await _automate();
    } catch (error) {
      const directory = String.fromEnvironment('LIVESYNC_RENDERER_AUTOMATION_DIR');
      if (directory.isNotEmpty) {
        await File('$directory/failure.json').writeAsString(
          jsonEncode({'passed': false, 'phase': phase, 'error': error.toString(), 'syntheticFixture': true}),
        );
      }
      if (mounted) setState(() => status = 'Probe error: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // Optional CI handshake, only in this dedicated synthetic-fixture entrypoint.
  // The external driver captures the real native window before acknowledging
  // each state. Flutter screenshots alone would omit the native video surface.
  Future<void> _automate() async {
    const directory = String.fromEnvironment('LIVESYNC_RENDERER_AUTOMATION_DIR');
    if (directory.isEmpty) return;
    await Directory(directory).create(recursive: true);
    final originalSid = await player.getProperty('sid');
    final timeline = TimelineTracker()
      ..observe([
        const SubtitleAnchor(0, 100, 104, 0.35, 'first independent calibration phrase'),
        const SubtitleAnchor(1, 110, 114, 0.35, 'second independent calibration phrase'),
      ]);
    final steps = <(String, String, String, String, String)>[
      ('baseline', 'sub-delay', '0.125', 'FIRST PROBE CUE', 'yes'),
      ('positive', 'sub-delay', '2.125', '', 'yes'),
      ('negative', 'sub-delay', '-3', 'SECOND PROBE CUE', 'yes'),
      ('restored', 'sub-delay', '0.125', 'FIRST PROBE CUE', 'yes'),
      ('gap-hidden', 'livesync-suppression', 'yes', 'FIRST PROBE CUE', 'no'),
      ('gap-shown-manual', 'sub-visibility', 'yes', 'FIRST PROBE CUE', 'no'),
      ('gap-restored', 'livesync-suppression', 'no', 'FIRST PROBE CUE', 'yes'),
      ('gap-hidden-again', 'livesync-suppression', 'yes', 'FIRST PROBE CUE', 'no'),
      ('gap-manual-hidden', 'sub-visibility', 'no', 'FIRST PROBE CUE', 'no'),
      ('gap-release-manual-hidden', 'livesync-suppression', 'no', 'FIRST PROBE CUE', 'no'),
      ('manual-shown', 'sub-visibility', 'yes', 'FIRST PROBE CUE', 'yes'),
      ('prediction-contradicted', 'prediction-evidence', 'contradicted', 'FIRST PROBE CUE', 'no'),
      ('prediction-manual-shown', 'sub-visibility', 'yes', 'FIRST PROBE CUE', 'no'),
      ('prediction-recovered', 'prediction-evidence', 'recovered', 'FIRST PROBE CUE', 'yes'),
      ('capture-on', 'livesync-enabled', 'yes', 'FIRST PROBE CUE', 'yes'),
      ('capture-off', 'livesync-enabled', 'no', 'FIRST PROBE CUE', 'yes'),
    ];
    try {
      for (final (name, property, value, expectedCue, expectedVisibility) in steps) {
        if (property == 'prediction-evidence') {
          timeline.observe([
            if (value == 'contradicted') const SubtitleAnchor(2, 130, 164, 0.35, 'third independent fixture phrase'),
            SubtitleAnchor(3, 140, value == 'contradicted' ? 172 : 174, 0.35, 'fourth independent fixture phrase'),
          ]);
          final correction = timeline.correctionAt(180);
          if (correction.predictionContradicted != (value == 'contradicted') || timeline.map.gaps.isNotEmpty) {
            throw StateError('Prediction presentation policy mismatch');
          }
          // Exercise the domain decision and actual native visibility without
          // pretending these injected anchors came from the renderer fixture.
          await (player as PlayerNative).setLiveSubtitleSuppressed(correction.suppressSubtitles);
        } else if (property == 'livesync-suppression') {
          await (player as PlayerNative).setLiveSubtitleSuppressed(value == 'yes');
        } else {
          await player.setProperty(property, value);
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
        final cue = (await player.getProperty('sub-text') ?? '').trim();
        final sid = await player.getProperty('sid');
        final delay = await player.getProperty('sub-delay');
        final visibility = await player.getProperty('sub-visibility');
        if (cue != expectedCue || sid != originalSid) throw StateError('Renderer state mismatch: $name');
        if (visibility != expectedVisibility) throw StateError('Renderer visibility mismatch: $name');
        if ((name == 'restored' || property != 'sub-delay') && double.tryParse(delay ?? '') != 0.125) {
          throw StateError('Manual delay changed: $name');
        }
        await _describe(name);
        await WidgetsBinding.instance.endOfFrame;
        final temporary = File('$directory/$name.tmp');
        await temporary.writeAsString(
          jsonEncode({
            'state': name,
            'cue': cue,
            'sid': sid,
            'delay': delay,
            'visibility': visibility,
            'automaticGapDetectionValidated': false,
            'predictionContradicted': timeline.correctionAt(180).predictionContradicted,
            'timingAnchorsInjected': true,
            'syntheticFixture': true,
            'audioOutput': Platform.isWindows ? 'pcm-to-NUL' : 'null',
            'videoBackend': Platform.isWindows ? 'd3d11-warp' : 'platform-default',
            'audiblePlaybackValidated': false,
          }),
          flush: true,
        );
        await temporary.rename('$directory/$name.json');
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!await File('$directory/$name.ack').exists()) {
          if (DateTime.now().isAfter(deadline)) throw TimeoutException('Renderer capture acknowledgement');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      await File('$directory/complete.json').writeAsString(jsonEncode({'states': steps.length, 'passed': true}));
    } catch (_) {
      await File('$directory/failure.json').writeAsString(jsonEncode({'passed': false}));
      rethrow;
    }
  }

  Future<void> _describe(String label) async {
    final time = await player.getProperty('time-pos');
    final delay = await player.getProperty('sub-delay');
    final capture = await player.getProperty('livesync-enabled');
    final sid = await player.getProperty('sid');
    final cue = await player.getProperty('sub-text');
    if (mounted) {
      setState(() => status = '$label | media=$time | delay=$delay | PCM tap=$capture | sid=$sid | cue=$cue');
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await _describe(label);
    } catch (error) {
      if (mounted) setState(() => status = 'Probe error: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    unawaited(player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(title: const Text('Plezy + LiveSync — native renderer feasibility')),
    body: Column(
      children: [
        Expanded(
          child: videoReady ? Video(player: player) : const Center(child: CircularProgressIndicator()),
        ),
        ColoredBox(
          color: const Color(0xff182438),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(status),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => _run('Delay +2.125 s', () => player.setProperty('sub-delay', '2.125')),
                      child: const Text('Delay +2 s'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : () => _run('Delay -3 s', () => player.setProperty('sub-delay', '-3')),
                      child: const Text('Delay -3 s'),
                    ),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => _run('Manual delay restored', () => player.setProperty('sub-delay', '0.125')),
                      child: const Text('Restore manual'),
                    ),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => _run('Capture enabled', () => player.setProperty('livesync-enabled', 'yes')),
                      child: const Text('Capture on'),
                    ),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => _run('Capture disabled', () => player.setProperty('livesync-enabled', 'no')),
                      child: const Text('Capture off'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : () => _run('Playback toggled', player.playOrPause),
                      child: const Text('Play / pause'),
                    ),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => _run('Seek to 1.5 s', () => player.seek(const Duration(milliseconds: 1500))),
                      child: const Text('Seek 1.5 s'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Synthetic fixture. These controls test native behavior; automatic sync is not implemented.',
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
