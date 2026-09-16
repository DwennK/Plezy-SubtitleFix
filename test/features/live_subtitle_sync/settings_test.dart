import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/model_manager.dart';
import 'package:plezy/features/live_subtitle_sync/settings.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';

void main() {
  Future<void> pump(WidgetTester tester, LiveSubtitleSyncSettings settings) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.fr));
    addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.en));
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(body: settings),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('cache removal disables both actions and reports success only after completion', (tester) async {
    final operation = Completer<bool>();
    var calls = 0;
    await pump(
      tester,
      LiveSubtitleSyncSettings(
        clearCache: () {
          calls++;
          return operation.future;
        },
      ),
    );
    await tester.tap(find.text(t.liveSubtitleSync.clearCache));
    await tester.pump();
    expect(calls, 1);
    expect(tester.widgetList<FocusableListTile>(find.byType(FocusableListTile)).every((tile) => !tile.enabled), isTrue);
    expect(find.text(t.liveSubtitleSync.cacheCleared), findsNothing);
    operation.complete(true);
    await tester.pumpAndSettle();
    expect(find.text(t.liveSubtitleSync.cacheCleared), findsOneWidget);
  });

  testWidgets('failed removal is not reported as success', (tester) async {
    await pump(tester, LiveSubtitleSyncSettings(clearCache: () async => false));
    await tester.tap(find.text(t.liveSubtitleSync.clearCache));
    await tester.pumpAndSettle();
    expect(find.text(t.liveSubtitleSync.storageFailed), findsOneWidget);
    expect(find.text(t.liveSubtitleSync.cacheCleared), findsNothing);
  });

  testWidgets('a model lease explains why deletion requires stopping analysis', (tester) async {
    await pump(
      tester,
      LiveSubtitleSyncSettings(
        deleteModel: () async {
          throw const ModelException(ModelFailure.inUse);
        },
      ),
    );
    await tester.tap(find.text(t.liveSubtitleSync.deleteModel));
    await tester.pumpAndSettle();
    expect(find.text(t.liveSubtitleSync.modelInUse), findsOneWidget);
    expect(find.text(t.liveSubtitleSync.modelDeleted), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
