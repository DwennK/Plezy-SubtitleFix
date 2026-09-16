import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/controller.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  test('track changes retry a requested session, but a user stop wins during teardown', () async {
    Completer<void>? stopWrite;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'setProperty' && (call.arguments as Map)['name'] == 'sub-delay') {
          await stopWrite?.future;
        }
        return null;
      },
      testBody: () async {
        final player = PlayerNative();
        final sync = LiveSubtitleSyncController.forPlayer(player);
        try {
          // Unsupported metadata prevents any download, native capture or ASR.
          // This test exercises lifecycle arbitration, not native inference.
          await sync.enable();
          expect(sync.phase, LiveSyncPhase.unsupported);
          expect(sync.reason, LiveSyncReason.englishTracks);
          player.handlePropertyChange('track-list', [
            {'type': 'audio', 'id': 1, 'lang': 'fr', 'selected': true},
          ]);
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          expect(sync.enabled, isTrue);
          expect(sync.phase, LiveSyncPhase.unsupported);

          stopWrite = Completer<void>();
          player.handlePropertyChange('track-list', [
            {'type': 'audio', 'id': 2, 'lang': 'de', 'selected': true},
          ]);
          await Future<void>.delayed(Duration.zero);
          final stopped = sync.disable();
          stopWrite!.complete();
          await stopped;
          await Future<void>.delayed(Duration.zero);
          expect(sync.enabled, isFalse);
          expect(sync.phase, LiveSyncPhase.off);
        } finally {
          if (stopWrite != null && !stopWrite!.isCompleted) stopWrite!.complete();
          await player.dispose();
        }
      },
    );
  }, skip: !Platform.isMacOS);
}
