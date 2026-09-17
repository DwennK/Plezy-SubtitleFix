import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/runtime_diagnostics.dart';

void main() {
  test('diagnostic output retains numerical evidence and rejects dialogue and credentials', () {
    final lines = <String>[];
    final diagnostics = LiveSyncRuntimeDiagnostics(lines.add);
    diagnostics.record({
      'phase': 'synced',
      'match': 'matched',
      'inferenceSeconds': 1.2,
      'windowStart': 'private-dialogue',
      'reason': 'private-secret',
      'url': 'https://private.test/?token=private-secret',
      'transcript': 'private-dialogue',
      'anchors': [
        {'cue': 4, 'offset': 3.72, 'phrase': 'private-dialogue'},
      ],
      'anchorRejections': {'beginningLowConfidence': 2, 'private-dialogue': 1},
    });
    expect(lines.single, isNot(contains('private')));
    final data = jsonDecode(lines.single.substring(LiveSyncRuntimeDiagnostics.prefix.length));
    expect(data, {
      'sequence': 1,
      'phase': 'synced',
      'match': 'matched',
      'inferenceSeconds': 1.2,
      'anchors': [
        {'cue': 4, 'offset': 3.72},
      ],
      'anchorRejections': {'beginningLowConfidence': 2},
    });
  });

  test('diagnostic output is bounded and nonfinite or malformed values are discarded', () {
    final lines = <String>[];
    final diagnostics = LiveSyncRuntimeDiagnostics(lines.add, maximumEvents: 2);
    diagnostics.record({'inferenceSeconds': double.nan, 'activityVoicePresent': 'private'});
    diagnostics.record({
      'anchors': List.generate(1000, (i) => {'cue': i, 'offset': double.infinity}),
      'anchorRejections': {'beginningLowConfidence': 'private'},
    });
    diagnostics.record({'phase': 'unable'});
    diagnostics.record({'phase': 'synced'});
    expect(lines, hasLength(2));
    final data = jsonDecode(lines.first.substring(LiveSyncRuntimeDiagnostics.prefix.length));
    expect(data['anchors'], hasLength(64));
    expect(data['anchors'][0], {'cue': 0});
    expect(lines.join(), isNot(contains('private')));
    expect(lines.join(), isNot(contains('Infinity')));
  });

  test('a failed diagnostic sink stops reporting without failing playback', () {
    var writes = 0;
    final diagnostics = LiveSyncRuntimeDiagnostics((_) {
      writes++;
      throw StateError('closed');
    });
    diagnostics.record({'phase': 'synced'});
    diagnostics.record({'phase': 'unable'});
    expect(writes, 1);
  });
}
