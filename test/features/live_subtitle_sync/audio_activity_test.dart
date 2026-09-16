import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/audio_activity.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';

Float32List tone(double frequency, {double offset = 0, double amplitude = 0.05}) => Float32List.fromList([
  for (var i = 0; i < 32000; i++) amplitude * math.sin(2 * math.pi * frequency * (offset + i / 16000)),
]);

void main() {
  test('window onsets retain early boundaries, quiet evidence and active duration without PCM', () {
    final samples = Float32List(240000);
    samples.setRange(16000, 48000, tone(250));
    samples.setRange(160000, 192000, tone(250));
    final onsets = VoiceActivityDetector.scanWindow(samples, start: 100, secondsPerSample: 1 / 16000);
    expect(onsets, hasLength(2));
    expect(onsets.first.start, closeTo(101, 0.04));
    expect(onsets.first.precedingQuietSeconds, closeTo(1, 0.04));
    expect(onsets.first.activeSeconds, closeTo(2, 0.04));
    expect(onsets.last.start, closeTo(110, 0.04));
    expect(onsets.last.precedingQuietSeconds, greaterThan(6.5));
    expect(samples[17000], isNot(0));
    final scaled = VoiceActivityDetector.scanWindow(samples, start: 100, secondsPerSample: 2 / 16000);
    expect(scaled.first.start, closeTo(102, 0.08));
    expect(scaled.last.start, closeTo(120, 0.08));
  });

  test('window onset hints do not invent preceding silence and reject corrupt or oversized PCM', () {
    final clipped = VoiceActivityDetector.scanWindow(tone(250), start: 10, secondsPerSample: 1 / 16000);
    expect(clipped.single.precedingQuietSeconds, 0);
    for (final samples in [Float32List(240001), Float32List(32000)..[0] = double.nan]) {
      expect(VoiceActivityDetector.scanWindow(samples, start: 0, secondsPerSample: 1 / 16000), isEmpty);
    }
    expect(VoiceActivityDetector.scanWindow(tone(250), start: double.nan, secondsPerSample: 1 / 16000), isEmpty);
  });

  test('silence and low rumble do not count as voice; speech-band tone is only an activity hint', () {
    for (final samples in [Float32List(32000), tone(40)]) {
      final result = VoiceActivityDetector().observe(
        samples,
        generation: 1,
        continuity: 0,
        start: 0,
        secondsPerSample: 1 / 16000,
      )!;
      expect(result.observedSeconds, closeTo(2, 1e-6));
      expect(result.voiceSeconds, 0);
    }
    // A tone is deliberately accepted: this heuristic cannot prove dialogue.
    final voiced = VoiceActivityDetector().observe(
      tone(250),
      generation: 1,
      continuity: 0,
      start: 0,
      secondsPerSample: 1 / 16000,
    )!;
    expect(voiced.voiceSeconds, greaterThan(1.8));
  });

  test('overlapping snapshots are counted once and media speed scales durations', () {
    final detector = VoiceActivityDetector();
    AudioActivity read(double start) =>
        detector.observe(tone(250), generation: 1, continuity: 0, start: start, secondsPerSample: 2 / 16000)!;
    final first = read(100);
    expect(first.start, 100);
    expect(first.end, closeTo(104, 1e-6));
    final repeated = read(100);
    expect(repeated.voiceSeconds, first.voiceSeconds);
    final overlap = read(101);
    expect(overlap.start, 100);
    expect(overlap.end, closeTo(105, 1e-6));
    expect(overlap.voiceSeconds, closeTo(5, 0.05));
  });

  test('silence expires activity; history stays bounded to twelve media seconds', () {
    final detector = VoiceActivityDetector();
    detector.observe(tone(250), generation: 1, continuity: 0, start: 0, secondsPerSample: 1 / 16000);
    AudioActivity? last;
    for (var i = 1; i < 40; i++) {
      last = detector.observe(
        Float32List(32000),
        generation: 1,
        continuity: 0,
        start: i * 2.0,
        secondsPerSample: 1 / 16000,
      );
    }
    expect(last!.voiceSeconds, 0);
    expect(last.observedSeconds, closeTo(12, 1e-6));
    expect(last.end, closeTo(80, 1e-6));
  });

  test('seek, generation change and missing PCM revoke earlier voice history', () {
    for (final changed in [(2, 0, 0.0), (1, 1, 0.0), (1, 0, 10.0)]) {
      final detector = VoiceActivityDetector();
      detector.observe(tone(250), generation: 1, continuity: 0, start: 0, secondsPerSample: 1 / 16000);
      final reset = detector.observe(
        Float32List(32000),
        generation: changed.$1,
        continuity: changed.$2,
        start: changed.$3,
        secondsPerSample: 1 / 16000,
      )!;
      expect(reset.voiceSeconds, 0);
      expect(reset.start, changed.$3);
    }
  });

  test('invalid samples clear private analysis history', () {
    final detector = VoiceActivityDetector();
    detector.observe(tone(250), generation: 1, continuity: 0, start: 0, secondsPerSample: 1 / 16000);
    final corrupt = Float32List(32000)..[0] = double.nan;
    expect(detector.observe(corrupt, generation: 1, continuity: 0, start: 2, secondsPerSample: 1 / 16000), isNull);
    final reset = detector.observe(
      Float32List(32000),
      generation: 1,
      continuity: 0,
      start: 4,
      secondsPerSample: 1 / 16000,
    )!;
    expect(reset.voiceSeconds, 0);
    expect(reset.start, 4);
  });

  test('subtitle speech expectation unions overlaps and ignores sound-only cues', () {
    final index = SubtitleIndex(
      ParsedSubtitles(SubtitleEncoding.utf8, [
        for (final (ordinal, start, end, text) in [
          (0, 2, 6, 'Bring the silver lantern'),
          (1, 4, 8, 'Walk across the bridge'),
          (2, 10, 12, '[music]'),
        ])
          SubtitleCue(
            ordinal: ordinal,
            sourceId: null,
            start: Duration(seconds: start),
            end: Duration(seconds: end),
            text: text,
            timingSuffix: '',
          ),
      ]),
    );
    expect(index.dialogueSecondsBetween(0, 20), 6);
    expect(index.dialogueSecondsBetween(3, 5), 2);
    expect(index.dialogueSecondsBetween(8, 20), 0);
    expect(index.dialogueSecondsBetween(double.nan, 20), 0);
  });
}
