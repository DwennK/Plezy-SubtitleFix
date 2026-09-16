// Executable integration proof with the real native libraries and redistributable
// JFK fixture. Runs in an isolate; it is not a Flutter renderer/performance test.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:plezy/features/live_subtitle_sync/native_bindings.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/transcript_context.dart';
import 'package:plezy/features/live_subtitle_sync/text_normalization.dart';

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<Map<String, Object>> probe(Map<String, String> options) async {
  final mpv = DynamicLibrary.open(File(options['mpv']!).absolute.path);
  final create = mpv.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('mpv_create');
  final initialize = mpv.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('mpv_initialize');
  final set = mpv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
      >('mpv_set_property_string');
  final setOption = mpv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
      >('mpv_set_option_string');
  final command = mpv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)
      >('mpv_command');
  final terminate = mpv.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'mpv_terminate_destroy',
  );
  final weak = mpv
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)
      >('mpv_create_weak_client');
  final player = create();
  require(player != nullptr, 'mpv creation failed');
  NativeLiveSyncEngine? engine;
  void property(String name, String value, {bool option = false}) {
    using(
      (arena) => require(
        (option ? setOption : set)(player, name.toNativeUtf8(allocator: arena), value.toNativeUtf8(allocator: arena)) >=
            0,
        'mpv property failed: $name',
      ),
    );
  }

  void runCommand(List<String> arguments) {
    using((arena) {
      final values = arena<Pointer<Utf8>>(arguments.length + 1);
      for (var i = 0; i < arguments.length; i++) {
        values[i] = arguments[i].toNativeUtf8(allocator: arena);
      }
      values[arguments.length] = nullptr;
      require(command(player, values) >= 0, 'mpv command failed');
    });
  }

  NativeMpvClient client() => using((arena) {
    final handle = weak(player, 'livesync_dart_probe'.toNativeUtf8(allocator: arena));
    require(handle != nullptr, 'weak client unavailable');
    return NativeMpvClient([
      handle.address,
      for (final name in ['get_property', 'set_property_string', 'free_node_contents', 'wait_event', 'destroy'])
        mpv.lookup<Void>('mpv_$name').address,
    ]);
  });
  try {
    for (final entry in {
      'config': 'no',
      'vo': 'null',
      'ao': 'null',
      'terminal': 'no',
      'msg-level': 'all=no',
      'keep-open': 'yes',
      'idle': 'yes',
    }.entries) {
      property(entry.key, entry.value, option: true);
    }
    require(initialize(player) >= 0, 'mpv initialization failed');
    engine = NativeLiveSyncEngine.open(
      client: client(),
      captureLibrary: File(options['capture']!).absolute.path,
      inferenceLibrary: File(options['inference']!).absolute.path,
      acceleratedInferenceLibrary: options['accelerated-inference'],
      modelPath: File(options['model']!).absolute.path,
      generation: 1,
    );
    // Failure must dispose only the rejected weak client, leaving the active tap.
    var duplicateRejected = false;
    try {
      final duplicate = NativeLiveSyncEngine.open(
        client: client(),
        captureLibrary: File(options['capture']!).absolute.path,
        inferenceLibrary: File(options['inference']!).absolute.path,
        acceleratedInferenceLibrary: options['accelerated-inference'],
        modelPath: File(options['model']!).absolute.path,
        generation: 1,
      );
      duplicate.close();
    } on NativeSyncException catch (error) {
      duplicateRejected = error.reason == NativeSyncFailure.captureUnavailable;
    }
    require(duplicateRejected, 'duplicate capture was accepted');
    runCommand(['loadfile', File(options['audio']!).absolute.path]);
    if (options['srt'] != null) {
      final expectedOffset = double.parse(options['expected-offset'] ?? '-100');
      final maximumError = double.parse(options['maximum-error'] ?? '1.5');
      final analysisSeconds = int.parse(options['analysis-seconds'] ?? '75');
      require(expectedOffset.isFinite && expectedOffset.abs() <= 600, 'Invalid expected offset');
      require(maximumError.isFinite && maximumError > 0 && maximumError <= 1.5, 'Invalid error bound');
      require(analysisSeconds >= 15 && analysisSeconds <= 900, 'Invalid analysis duration');
      final index = SubtitleIndex(const SubtitleParser().parse(await File(options['srt']!).readAsBytes()));
      final estimator = ConstantOffsetEstimator();
      final context = TranscriptContext();
      final clock = Stopwatch()..start();
      var last = -60000;
      var attempts = 0;
      var windowSeconds = 12.0;
      final analyses = <Map<String, Object?>>[];
      double? offset;
      while (clock.elapsedMilliseconds < analysisSeconds * 1000 && offset == null) {
        final capture = engine.status();
        try {
          final transcript = engine.takeResult();
          if (transcript != null) {
            final adjacent = context.add(transcript);
            final evidence = matchTranscriptEvidence(transcript, index, context: adjacent);
            final words = const DialogueNormalizer().words(
              transcript.segments.map((segment) => segment.text).join(' '),
            );
            final result = evidence.match;
            final anchors = evidence.anchors;
            windowSeconds = anchors.isEmpty ? 15 : 12;
            offset = estimator.add(anchors);
            analyses.add({
              'attempt': attempts,
              'windowStart': transcript.windowStart,
              'windowEnd': transcript.windowEnd,
              'match': result.status.name,
              'contextWindows': evidence.windowCount,
              'segmentedMatch': evidence.segmented,
              'transcriptWords': words.length,
              'wordsInSubtitleVocabulary': words.where((word) => index.positionsOf(word).isNotEmpty).length,
              'contextWords': adjacent == null
                  ? 0
                  : const DialogueNormalizer().words(adjacent.segments.map((segment) => segment.text).join(' ')).length,
              'segmentBounds': [
                for (final segment in transcript.segments)
                  {
                    'start': segment.start,
                    'end': segment.end,
                    'timedTokens': segment.tokens.where((token) => token.hasTimestamp).length,
                    'firstToken': segment.tokens.isEmpty ? null : segment.tokens.first.start,
                    'lastToken': segment.tokens.isEmpty ? null : segment.tokens.last.end,
                  },
              ],
              'similarity': result.passage?.similarity,
              'anchors': anchors.map((anchor) => {'cue': anchor.cue, 'offset': anchor.offset}).toList(),
            });
          }
        } on NativeSyncException catch (error) {
          analyses.add({'attempt': attempts, 'failure': error.reason.name});
        }
        final interval = attempts > 3 ? 30000 : 12000;
        if (capture.samples >= 128000 &&
            clock.elapsedMilliseconds - last >= interval &&
            engine.submitRecent(seconds: windowSeconds)) {
          last = clock.elapsedMilliseconds;
          attempts++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (offset != null) property('sub-delay', offset.toString());
      return {
        'kind': 'native-active-pcm-real-asr-and-domain-alignment',
        'platform': Platform.operatingSystem,
        'inferenceBackend': engine.inferenceBackend,
        'actualOffset': offset ?? 'none',
        'acquisitionMs': clock.elapsedMilliseconds,
        'expectedOffset': expectedOffset,
        'absoluteOffsetError': offset == null ? 'unavailable' : (offset - expectedOffset).abs(),
        'maximumOffsetError': maximumError,
        'reference': 'authored SRT timings, not precise acoustic-onset ground truth',
        'passed': offset != null && (offset - expectedOffset).abs() < maximumError,
        'analyses': analyses,
        'productionPlayerValidated': false,
        'audiblePlaybackValidated': false,
        'pcmOrTranscriptPersisted': false,
      };
    }
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (engine.status().samples < 136000) {
      require(DateTime.now().isBefore(deadline), 'PCM capture timed out');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    property('pause', 'yes');
    require(engine.submitRecent(seconds: 9), 'inference submission rejected');
    require(!engine.submitRecent(seconds: 9), 'duplicate inference accepted');
    NativeTranscript? transcript;
    final recognitionDeadline = DateTime.now().add(const Duration(seconds: 90));
    while (transcript == null) {
      require(DateTime.now().isBefore(recognitionDeadline), 'inference timed out');
      transcript = engine.takeResult();
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final words = transcript.segments.map((segment) => segment.text).join(' ').toLowerCase();
    require(words.contains('fellow americans'), 'known fixture dialogue not recognized');
    require(transcript.generation == 1 && transcript.segments.isNotEmpty, 'invalid result generation');
    require(
      transcript.segments.expand((segment) => segment.tokens).any((token) => token.hasTimestamp),
      'token timestamps unavailable',
    );
    require(engine.takeResult() == null, 'result was returned twice');
    engine.reset(2);
    require(engine.status().generation == 2 && engine.status().samples == 0, 'reset did not clear PCM');
    require(engine.takeResult() == null, 'reset retained a transcript');
    final report = <String, Object>{
      'kind': 'dart-isolate-real-native-capture-and-inference',
      'inferenceBackend': engine.inferenceBackend,
      'platform': Platform.operatingSystem,
      'generationReset': true,
      'duplicateCaptureRejected': duplicateRejected,
      'singleInferenceEnforced': true,
      'fixtureDialogueRecognized': true,
      'windowStart': transcript.windowStart,
      'windowEnd': transcript.windowEnd,
      'segments': transcript.segments.length,
      'tokens': transcript.segments.fold<int>(0, (sum, segment) => sum + segment.tokens.length),
      'inferenceSeconds': transcript.elapsed,
      'productionPlayerValidated': false,
      'audiblePlaybackValidated': false,
      'pcmOrTranscriptPersisted': false,
    };
    engine.close();
    engine.close(); // Idempotent teardown.
    engine = null;
    return report;
  } finally {
    engine?.close();
    terminate(player);
  }
}

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (var i = 0; i < arguments.length; i += 2) {
    require(i + 1 < arguments.length && arguments[i].startsWith('--'), 'Expected --key value');
    options[arguments[i].substring(2)] = arguments[i + 1];
  }
  for (final key in ['mpv', 'capture', 'inference', 'model', 'audio', 'output']) {
    require(options.containsKey(key), 'Missing $key');
  }
  var ticks = 0;
  final heartbeat = Timer.periodic(const Duration(milliseconds: 25), (_) => ticks++);
  try {
    final report = await Isolate.run(() => probe(options));
    require(ticks > 100, 'main isolate heartbeat did not advance');
    report['mainIsolateHeartbeatTicks'] = ticks;
    final file = File(options['output']!);
    await file.parent.create(recursive: true);
    await file.writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    require(report['passed'] != false, 'Alignment did not acquire the expected offset; inspect the summary');
    stdout.writeln('Native Dart integration passed; no dialogue or PCM retained.');
  } finally {
    heartbeat.cancel();
  }
}
