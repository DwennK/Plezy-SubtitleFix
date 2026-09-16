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
  test('automatic and manual delays compose and disable removes only automatic input', () async {
    final delays = <double>[];
    var reject = false;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'setProperty' && (call.arguments as Map)['name'] == 'sub-delay') {
          if (reject) throw PlatformException(code: 'PROPERTY_ERROR');
          delays.add(double.parse((call.arguments as Map)['value'] as String));
        }
        return null;
      },
      testBody: () async {
        final player = PlayerNative();
        try {
          await player.setProperty('sub-delay', '0.125');
          await player.setLiveSubtitleOffset(90);
          await player.setProperty('sub-delay', '-0.25');
          await player.setLiveSubtitleOffset(0);
          expect(delays, [0.125, 90.125, 89.75, -0.25]);
          reject = true;
          await expectLater(player.setLiveSubtitleOffset(10), throwsA(isA<PlatformException>()));
          reject = false;
          await player.setProperty('sub-delay', '0.5');
          expect(delays.last, 0.5);
          await Future.wait([player.setLiveSubtitleOffset(3), player.setProperty('sub-delay', '1')]);
          expect(delays.sublist(delays.length - 2), [3.5, 4]);
        } finally {
          await player.dispose();
        }
      },
    );
  }, skip: !Platform.isMacOS && !Platform.isWindows);
}
