import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../mpv/models.dart';
import 'subtitle_index.dart';
import 'temporal_aligner.dart';
import 'timeline_map.dart';

String _digest(Object value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// Opaque local identity. URLs, credentials, titles and paths are never stored.
class LiveSyncMediaIdentity {
  const LiveSyncMediaIdentity._(this.digest);
  final String digest;

  static LiveSyncMediaIdentity? server({
    required String? server,
    required String item,
    required String version,
    required String part,
    required int? updatedAt,
    required int? sizeBytes,
    required int? durationMs,
  }) {
    final ids = [server, item, version, part];
    if (ids.any((id) => id == null || id.isEmpty || id.length > 512 || id.contains(RegExp(r'[:/?#]'))) ||
        updatedAt == null ||
        updatedAt <= 0 ||
        sizeBytes == null ||
        sizeBytes <= 0 ||
        durationMs == null ||
        durationMs <= 0) {
      return null;
    }
    return LiveSyncMediaIdentity._(_digest(['server', ...ids, updatedAt, sizeBytes, durationMs]));
  }

  static Future<LiveSyncMediaIdentity?> local(String uri) async {
    try {
      final parsed = Uri.tryParse(uri);
      if (parsed != null && parsed.hasScheme && parsed.scheme != 'file' && !p.isAbsolute(uri)) return null;
      final file = File(parsed?.scheme == 'file' ? parsed!.toFilePath() : uri);
      final path = await file.resolveSymbolicLinks();
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
      return LiveSyncMediaIdentity._(_digest(['local', path, stat.size, stat.modified.microsecondsSinceEpoch]));
    } on FileSystemException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}

class MappingCacheKey {
  const MappingCacheKey._(this.digest);
  final String digest;
  static const schema = 1;
  // Bump whenever recognition, fitting or timing semantics change.
  static const algorithm = 'bounded-affine-titles-v1';

  static MappingCacheKey? create(LiveSyncMediaIdentity media, AudioTrack audio, String subtitleHash) {
    if (!RegExp(r'^[0-9]+$').hasMatch(audio.id) ||
        audio.codec == null ||
        audio.language == null ||
        (audio.channels ?? 0) <= 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(subtitleHash)) {
      return null;
    }
    return MappingCacheKey._(
      _digest([
        schema,
        algorithm,
        media.digest,
        audio.id,
        audio.codec,
        audio.language,
        audio.channels,
        audio.sampleRate,
        audio.bitrate,
        subtitleHash,
      ]),
    );
  }
}

/// Bounded, atomic, best-effort local cache. Failures never prevent playback.
/// Only observed domains and numeric anchors are serialized; prediction state,
/// source text, recognition, PCM and credentials are excluded.
class MappingCache {
  MappingCache(this.directory, {this.maximumEntries = 100, this.maximumAge = const Duration(days: 90)});
  final Directory directory;
  final int maximumEntries;
  final Duration maximumAge;
  static const maximumBytes = 1024 * 1024;
  Future<void> _tail = Future.value();
  int _generation = 0;
  int get generation => _generation;

  File _file(MappingCacheKey key) => File(p.join(directory.path, '${key.digest}.json'));

  Future<T> _serial<T>(Future<T> Function() operation) {
    final work = _tail.then((_) => operation());
    _tail = work.then<void>((_) {}, onError: (Object _) {});
    return work;
  }

  Future<TimelineMap?> read(MappingCacheKey key, SubtitleIndex index) => _serial(() async {
    final file = _file(key);
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      if (stat.size > maximumBytes || DateTime.now().difference(stat.modified) > maximumAge) {
        await file.delete();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in file.openRead()) {
        if (bytes.length + chunk.length > maximumBytes) throw const FormatException('Cache size');
        bytes.addAll(chunk);
      }
      return await compute(_decode, (bytes, key.digest, index));
    } catch (_) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        /* Best effort. */
      }
      return null;
    }
  });

  static TimelineMap _decode((List<int>, String, SubtitleIndex) input) {
    final (bytes, key, index) = input;
    final envelope = jsonDecode(utf8.decode(bytes)) as Map;
    final payload = envelope['payload'] as Map;
    if (envelope['checksum'] != _digest(payload) ||
        payload['schema'] != MappingCacheKey.schema ||
        payload['algorithm'] != MappingCacheKey.algorithm ||
        payload['key'] != key) {
      throw const FormatException('Cache identity');
    }
    final segments = payload['segments'] as List;
    final gaps = payload['gaps'] as List;
    if (segments.length > 128 || gaps.length > 128) throw const FormatException('Cache bounds');
    final starts = {
      for (var i = 0; i < index.words.length; i++)
        if (index.words[i].wordInCue == 0) index.words[i].cueOrdinal: i,
    };
    double number(Object? value) {
      if (value is! num || !value.isFinite) throw const FormatException('Cache number');
      return value.toDouble();
    }

    final result = TimelineMap(
      segments: [
        for (final raw in segments)
          TimelineSegment(
            subtitleStart: number(raw['start']),
            subtitleEnd: number(raw['end']),
            slope: number(raw['slope']),
            offset: number(raw['offset']),
            uncertainty: number(raw['uncertainty']),
            anchors: (raw['anchors'] as List).map((raw) {
              final cue = raw['cue'];
              final start = starts[cue];
              if (cue is! int ||
                  start == null ||
                  start + 2 >= index.words.length ||
                  index.words[start + 2].cueOrdinal != cue) {
                throw const FormatException('Cache cue');
              }
              final time = index.words[start].cueStart.inMicroseconds / 1e6;
              if (number(raw['subtitle']) != time) throw const FormatException('Cache cue time');
              final media = number(raw['media']);
              if (media < 0 || (media - time).abs() > 600) throw const FormatException('Cache offset');
              return SubtitleAnchor(
                cue,
                time,
                media,
                number(raw['uncertainty']),
                index.words.sublist(start, start + 3).map((word) => word.text).join(' '),
              );
            }).toList(),
          ),
      ],
      gaps: [
        for (final raw in gaps)
          TimelineGap(
            TimelineRegionKind.values.byName(raw['kind'] as String),
            number(raw['start']),
            number(raw['end']),
          ),
      ],
    );
    // Refit stored evidence to validate its domain and support. withSegment
    // retains earlier anchors when a later observation refines the same cue,
    // so the stored correction need not equal a fresh fit bit for bit. It
    // must still explain every anchor (TimelineSegment) and both endpoints
    // within the same production residual bound.
    for (final segment in result.segments) {
      final fit = const TimelineFitter().fit(segment.anchors);
      if (fit == null ||
          (fit.mediaStart - segment.mediaStart).abs() > 0.8 ||
          (fit.mediaEnd - segment.mediaEnd).abs() > 0.8 ||
          (segment.slope != 1 && (segment.anchors.length < 6 || segment.subtitleEnd - segment.subtitleStart < 60)) ||
          (fit.subtitleStart - segment.subtitleStart).abs() > 1e-6 ||
          (fit.subtitleEnd - segment.subtitleEnd).abs() > 1e-6) {
        throw const FormatException('Cache evidence');
      }
    }
    return result;
  }

  static List<int> _encode(Map<String, Object> payload) =>
      utf8.encode(jsonEncode({'payload': payload, 'checksum': _digest(payload)}));

  Future<void> write(MappingCacheKey key, TimelineMap map, {required int generation}) => _serial(() async {
    if (generation != _generation) return;
    File? temporary;
    try {
      if (map.segments.isEmpty) {
        final file = _file(key);
        if (await file.exists()) await file.delete();
        return;
      }
      final payload = {
        'schema': MappingCacheKey.schema,
        'algorithm': MappingCacheKey.algorithm,
        'key': key.digest,
        'segments': [
          for (final s in map.segments)
            {
              'start': s.subtitleStart,
              'end': s.subtitleEnd,
              'slope': s.slope,
              'offset': s.offset,
              'uncertainty': s.uncertainty,
              'anchors': [
                for (final a in s.anchors)
                  {'cue': a.cue, 'subtitle': a.subtitleTime, 'media': a.mediaTime, 'uncertainty': a.uncertainty},
              ],
            },
        ],
        'gaps': [
          for (final g in map.gaps) {'kind': g.kind.name, 'start': g.start, 'end': g.end},
        ],
      };
      final bytes = await compute(_encode, payload);
      if (bytes.length > maximumBytes) return;
      await directory.create(recursive: true);
      temporary = File(p.join(directory.path, '${key.digest}.${const Uuid().v4()}.tmp'));
      await temporary.writeAsBytes(bytes, flush: true);
      if (generation != _generation) return;
      await temporary.rename(_file(key).path);
      await _prune();
    } catch (_) {
      // Storage is optional; never alter the live correction on write failure.
    } finally {
      try {
        if (temporary != null && await temporary.exists()) await temporary.delete();
      } catch (_) {
        /* Best effort. */
      }
    }
  });

  Future<bool> clear() {
    ++_generation; // Invalidate writes from every already-running controller.
    return _serial(() async {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return !await directory.exists();
      } catch (_) {
        return false;
      }
    });
  }

  Future<void> _prune() async {
    final files = <(File, DateTime)>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final stat = await entry.stat();
      final age = DateTime.now().difference(stat.modified);
      if ((entry.path.endsWith('.tmp') && age > const Duration(days: 1)) || age > maximumAge) {
        await entry.delete();
      } else if (entry.path.endsWith('.json')) {
        files.add((entry, stat.modified));
      }
    }
    files.sort((a, b) => b.$2.compareTo(a.$2));
    for (final entry in files.skip(maximumEntries)) {
      await entry.$1.delete();
    }
  }
}
