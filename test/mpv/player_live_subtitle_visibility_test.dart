import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  Future<void> exercise(
    Future<void> Function(PlayerNative, List<String>) body, {
    String? initial = 'yes',
    Future<void> Function(String)? beforeWrite,
  }) async {
    final writes = <String>[];
    var native = initial;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'getProperty' && (call.arguments as Map)['name'] == 'sub-visibility') return native;
        if (call.method == 'setProperty' && (call.arguments as Map)['name'] == 'sub-visibility') {
          final value = (call.arguments as Map)['value'] as String;
          await beforeWrite?.call(value);
          native = value;
          writes.add(value);
        }
        return null;
      },
      testBody: () async {
        final player = PlayerNative();
        try {
          await body(player, writes);
        } finally {
          await player.dispose();
        }
      },
    );
  }

  group('LiveSync visibility composition', () {
    test('a mask preserves both initial native settings and repeated releases are harmless', () async {
      for (final initial in ['yes', 'no']) {
        await exercise((player, writes) async {
          await player.setLiveSubtitleSuppressed(false);
          expect(writes, isEmpty);
          await player.setLiveSubtitleSuppressed(true);
          await player.setLiveSubtitleSuppressed(true);
          await player.setLiveSubtitleSuppressed(false);
          await player.setLiveSubtitleSuppressed(false);
          expect(writes, ['no', initial]);
        }, initial: initial);
      }
    });

    test('manual hide during a mask survives release and a later mask', () async {
      await exercise((player, writes) async {
        await player.setLiveSubtitleSuppressed(true);
        await player.setProperty('sub-visibility', 'no');
        await player.setLiveSubtitleSuppressed(false);
        await player.setLiveSubtitleSuppressed(true);
        await player.setLiveSubtitleSuppressed(false);
        expect(writes, everyElement('no'));
        await player.setProperty('sub-visibility', 'yes');
        expect(writes.last, 'yes');
      });
    });

    test('manual show remains masked until the confirmed region ends', () async {
      await exercise((player, writes) async {
        await player.setLiveSubtitleSuppressed(true);
        await player.setProperty('sub-visibility', 'yes');
        expect(writes, ['no', 'no']);
        await player.setLiveSubtitleSuppressed(false);
        expect(writes.last, 'yes');
      }, initial: 'no');
    });

    test('queued manual changes and release cannot overtake an in-flight mask', () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      var first = true;
      await exercise(
        (player, writes) async {
          final mask = player.setLiveSubtitleSuppressed(true);
          await entered.future;
          final manual = player.setProperty('sub-visibility', 'no');
          final release = player.setLiveSubtitleSuppressed(false);
          resume.complete();
          await Future.wait([mask, manual, release]);
          expect(writes, ['no', 'no', 'no']);
        },
        beforeWrite: (_) async {
          if (first) {
            first = false;
            entered.complete();
            await resume.future;
          }
        },
      );
    });

    test('failed release keeps the mask owned and can be retried with the latest manual choice', () async {
      var reject = false;
      await exercise(
        (player, writes) async {
          await player.setLiveSubtitleSuppressed(true);
          reject = true;
          await expectLater(player.setLiveSubtitleSuppressed(false), throwsA(isA<PlatformException>()));
          reject = false;
          await player.setProperty('sub-visibility', 'no');
          await player.setLiveSubtitleSuppressed(false);
          expect(writes, ['no', 'no', 'no']);
        },
        beforeWrite: (_) async {
          if (reject) throw PlatformException(code: 'PROPERTY_ERROR');
        },
      );
    });

    test('missing initial state does not invent a visible preference or mutate native state', () async {
      await exercise((player, writes) async {
        await expectLater(player.setLiveSubtitleSuppressed(true), throwsStateError);
        expect(writes, isEmpty);
        await player.setProperty('sub-visibility', 'no');
        await player.setLiveSubtitleSuppressed(true);
        await player.setLiveSubtitleSuppressed(false);
        expect(writes, ['no', 'no', 'no']);
      }, initial: null);
    });
  }, skip: !Platform.isMacOS && !Platform.isWindows);
}
