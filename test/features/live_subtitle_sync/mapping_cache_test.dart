import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/mapping_cache.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_index.dart';
import 'package:plezy/features/live_subtitle_sync/subtitle_parser.dart';
import 'package:plezy/features/live_subtitle_sync/temporal_aligner.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_map.dart';
import 'package:plezy/features/live_subtitle_sync/timeline_tracker.dart';
import 'package:plezy/mpv/models.dart';

void main() {
  late Directory directory;
  late MappingCache cache;
  const audio = AudioTrack(id: '1', codec: 'aac', language: 'eng', channels: 2, sampleRate: 48000);
  final hash = sha256.convert(utf8.encode('subtitle fixture')).toString();
  LiveSyncMediaIdentity identity({int revision = 100, int size = 10000, String version = 'version-1'}) =>
      LiveSyncMediaIdentity.server(
        server: 'server',
        item: 'episode',
        version: version,
        part: 'part',
        updatedAt: revision,
        sizeBytes: size,
        durationMs: 150000,
      )!;
  MappingCacheKey key({LiveSyncMediaIdentity? media, AudioTrack track = audio, String? subtitleHash}) =>
      MappingCacheKey.create(media ?? identity(), track, subtitleHash ?? hash)!;
  const phrases = [
    'Bring the silver lantern',
    'Walk across that wooden bridge',
    'Open this heavy door',
    'Please find another path',
    'Stay beside your older brother',
    'Carry our last wooden box',
  ];
  final index = SubtitleIndex(
    ParsedSubtitles(SubtitleEncoding.utf8, [
      for (var i = 0; i < phrases.length; i++)
        SubtitleCue(
          ordinal: i,
          sourceId: null,
          start: Duration(seconds: 2 + i * 20),
          end: Duration(seconds: 6 + i * 20),
          text: phrases[i],
          timingSuffix: '',
        ),
    ]),
  );
  List<SubtitleAnchor> anchors({int count = 2, double slope = 1, double offset = 3}) => [
    for (var i = 0; i < count; i++)
      SubtitleAnchor(
        i,
        2 + i * 20,
        slope * (2 + i * 20) + offset,
        0.35,
        index.words.where((word) => word.cueOrdinal == i).take(3).map((word) => word.text).join(' '),
      ),
  ];
  TimelineMap map({int count = 2, double slope = 1, double offset = 3}) => TimelineMap(
    segments: [const TimelineFitter().fit(anchors(count: count, slope: slope, offset: offset))!],
  );
  Future<File> stored() async => (await directory.list().where((f) => f.path.endsWith('.json')).single) as File;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('livesync-mapping-');
    cache = MappingCache(directory);
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('keys distinguish media versions, audio and complete subtitle contents', () {
    final original = key().digest;
    expect(key().digest, original);
    for (final other in [
      key(media: identity(revision: 101)),
      key(media: identity(size: 10001)),
      key(media: identity(version: 'version-2')),
      key(track: audio.copyWith(id: '2')),
      key(track: audio.copyWith(channels: 6)),
      key(subtitleHash: sha256.convert([1]).toString()),
    ]) {
      expect(other.digest, isNot(original));
    }
    expect(MappingCacheKey.create(identity(), AudioTrack.auto, hash), isNull);
    expect(
      LiveSyncMediaIdentity.server(
        server: 'https://host?token=private',
        item: 'episode',
        version: 'v',
        part: 'p',
        updatedAt: 1,
        sizeBytes: 100,
        durationMs: 100,
      ),
      isNull,
    );
    expect(
      LiveSyncMediaIdentity.server(
        server: 's',
        item: 'episode',
        version: 'v',
        part: 'p',
        updatedAt: null,
        sizeBytes: 100,
        durationMs: 100,
      ),
      isNull,
    );
  });

  test('local identity changes on replacement and rejects remote URLs', () async {
    final file = File('${directory.path}/media.mkv');
    await file.writeAsBytes([1, 2, 3]);
    final first = await LiveSyncMediaIdentity.local(file.path);
    expect(first, isNotNull);
    expect((await LiveSyncMediaIdentity.local(file.uri.toString()))!.digest, first!.digest);
    await file.writeAsBytes([1, 2, 3, 4]);
    expect((await LiveSyncMediaIdentity.local(file.path))!.digest, isNot(first.digest));
    expect(await LiveSyncMediaIdentity.local('https://host/media?token=private'), isNull);
  });

  test('constant and affine regions round trip without persisted dialogue or predictions', () async {
    for (final slope in [1.0, 1.04]) {
      final original = map(count: 6, slope: slope);
      await cache.write(key(), original, generation: cache.generation);
      final restored = (await cache.read(key(), index))!;
      expect(restored.segments.single.slope, closeTo(slope, 1e-8));
      final tracker = TimelineTracker()..restore(restored);
      expect(tracker.hasUnvalidatedCache, isTrue);
      expect(tracker.correctionAt(40).position.automaticDelay, closeTo(original.atMedia(40).automaticDelay!, 1e-8));
      expect(tracker.correctionAt(140).position.kind, TimelineRegionKind.unknown);
      final text = await (await stored()).readAsString();
      expect(text, isNot(contains('lantern')));
      expect(text, isNot(contains('episode')));
      expect(text, isNot(contains('server')));
      expect(await directory.list().where((f) => f.path.endsWith('.tmp')).isEmpty, isTrue);
    }
  });

  test('corrupt, partial and oversized entries are discarded', () async {
    for (final content in ['{', '{"payload":{}}', 'x' * (MappingCache.maximumBytes + 1)]) {
      await cache.write(key(), map(), generation: cache.generation);
      final file = await stored();
      await file.writeAsString(content);
      expect(await cache.read(key(), index), isNull);
      expect(await file.exists(), isFalse);
    }
  });

  test('identity, schema, evidence and domain checks reject invalid envelopes', () async {
    for (final mutate in <void Function(Map)>[
      (p) => p['key'] = 'different',
      (p) => p['schema'] = 999,
      (p) => p['algorithm'] = 'old',
      (p) => p['segments'][0]['end'] = 900.0,
      (p) => p['segments'][0]['anchors'][0]['cue'] = 999,
      (p) => p['segments'][0]['anchors'][0]['subtitle'] = 3.0,
    ]) {
      await cache.write(key(), map(), generation: cache.generation);
      final file = await stored();
      final envelope = jsonDecode(await file.readAsString()) as Map;
      mutate(envelope['payload'] as Map);
      envelope['checksum'] = sha256.convert(utf8.encode(jsonEncode(envelope['payload']))).toString();
      await file.writeAsString(jsonEncode(envelope));
      expect(await cache.read(key(), index), isNull);
    }
  });

  test('clear invalidates queued writes and old active sessions', () async {
    final generation = cache.generation;
    final writing = cache.write(key(), map(), generation: generation);
    final clearing = cache.clear();
    await Future.wait([writing, clearing]);
    await cache.write(key(), map(), generation: generation);
    expect(await cache.read(key(), index), isNull);
    await cache.write(key(), map(), generation: cache.generation);
    expect(await cache.read(key(), index), isNotNull);
    await cache.write(key(), TimelineMap(), generation: cache.generation);
    expect(await cache.read(key(), index), isNull);
  });

  test('expiry and entry limit bound disk usage', () async {
    cache = MappingCache(directory, maximumEntries: 2);
    await cache.write(key(), map(), generation: cache.generation);
    await (await stored()).setLastModified(DateTime.now().subtract(const Duration(days: 91)));
    expect(await cache.read(key(), index), isNull);
    for (var i = 0; i < 3; i++) {
      await cache.write(
        key(media: identity(revision: i + 1)),
        map(),
        generation: cache.generation,
      );
    }
    expect(await directory.list().where((f) => f.path.endsWith('.json')).length, 2);
  });

  test('independent contradictory speech invalidates a restored region', () {
    final tracker = TimelineTracker()..restore(map());
    expect(tracker.observe([anchors(offset: 9).first]), isFalse);
    expect(tracker.correctionAt(20).position.automaticDelay, 3);
    expect(tracker.observe([anchors(offset: 9).last]), isTrue);
    expect(tracker.correctionAt(20).position.automaticDelay, 9);
    expect(tracker.hasUnvalidatedCache, isFalse);
    expect(tracker.map.segments, hasLength(1));
  });

  test('matching fresh evidence validates the restored region', () {
    final tracker = TimelineTracker()..restore(map());
    expect(tracker.observe(anchors(offset: 3.1)), isTrue);
    expect(tracker.hasUnvalidatedCache, isFalse);
    expect(tracker.correctionAt(20).position.automaticDelay, closeTo(3.1, 0.2));
  });

  test('a refined live map restores its exact correction while retaining old anchor evidence', () async {
    final tracker = TimelineTracker();
    expect(tracker.observe(anchors()), isTrue);
    expect(tracker.observe(anchors(offset: 3.1)), isTrue);
    final actual = tracker.correctionAt(20).position.automaticDelay;
    await cache.write(key(), tracker.map, generation: cache.generation);
    final restored = await cache.read(key(), index);
    expect(restored, isNotNull);
    expect(restored!.atMedia(20).automaticDelay, actual);
  });
}
