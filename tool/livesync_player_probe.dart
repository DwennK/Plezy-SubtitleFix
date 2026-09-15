/// Native feasibility harness using Plezy's actual Player and Video widgets.
/// Not a production entrypoint or an automatic synchronization implementation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:plezy/mpv/mpv.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      const directory = String.fromEnvironment('LIVESYNC_FIXTURE_DIR');
      final video = File('$directory/fixture.mkv');
      final subtitles = File('$directory/fixture.srt');
      if (directory.isEmpty || !video.existsSync() || !subtitles.existsSync()) {
        throw StateError('Build with LIVESYNC_FIXTURE_DIR containing fixture.mkv and fixture.srt');
      }
      final track = SubtitleTrack.uri(subtitles.path, language: 'eng', codec: 'srt');
      final tracksReady = player.streams.tracks
          .firstWhere((tracks) => tracks.subtitle.any((t) => t.uri == subtitles.path))
          .timeout(const Duration(seconds: 20));
      final ready = player.streams.playbackRestart.first.timeout(const Duration(seconds: 20));
      await player.setProperty('volume', '5');
      await player.configureSubtitleFonts();
      await player.open(
        Media(video.path, start: const Duration(milliseconds: 1500)),
        play: false,
        externalSubtitles: [track],
      );
      await ready;
      final available = await tracksReady;
      await player.selectSubtitleTrack(available.subtitle.firstWhere((t) => t.uri == subtitles.path));
      await player.setProperty('sub-delay', '0.125');
      await player.setProperty('sub-pos', '70');
      await player.setProperty('sub-font-size', '44');
      await _describe('Baseline: manual delay 0.125 s');
      await _automate();
    } catch (error) {
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
    final steps = <(String, String, String, String)>[
      ('baseline', 'sub-delay', '0.125', 'FIRST PROBE CUE'),
      ('positive', 'sub-delay', '2.125', ''),
      ('negative', 'sub-delay', '-3', 'SECOND PROBE CUE'),
      ('restored', 'sub-delay', '0.125', 'FIRST PROBE CUE'),
      ('capture-on', 'livesync-enabled', 'yes', 'FIRST PROBE CUE'),
      ('capture-off', 'livesync-enabled', 'no', 'FIRST PROBE CUE'),
    ];
    try {
      for (final (name, property, value, expectedCue) in steps) {
        await player.setProperty(property, value);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        final cue = (await player.getProperty('sub-text') ?? '').trim();
        final sid = await player.getProperty('sid');
        final delay = await player.getProperty('sub-delay');
        if (cue != expectedCue || sid != originalSid) throw StateError('Renderer state mismatch: $name');
        if ((name == 'restored' || name.startsWith('capture-')) && double.tryParse(delay ?? '') != 0.125) {
          throw StateError('Manual delay changed: $name');
        }
        await _describe(name);
        await WidgetsBinding.instance.endOfFrame;
        final temporary = File('$directory/$name.tmp');
        await temporary.writeAsString(
          jsonEncode({'state': name, 'cue': cue, 'sid': sid, 'delay': delay, 'syntheticFixture': true}),
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
        Expanded(child: Video(player: player)),
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
