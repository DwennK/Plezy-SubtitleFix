import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';

import '../test_helpers/prefs.dart';

class _IsolatedPaths extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  _IsolatedPaths(this.root);

  final Directory root;
  int documentsLookups = 0;

  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/LiveSync';

  @override
  Future<String?> getApplicationDocumentsPath() async {
    documentsLookups++;
    return '${root.path}/Documents';
  }
}

void main() {
  test('desktop fork never imports or moves the official legacy database', () async {
    resetSharedPreferencesForTest();
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final previous = PathProviderPlatform.instance;
    final root = await Directory.systemTemp.createTemp('livesync-isolation-');
    final paths = _IsolatedPaths(root);
    final legacy = File('${root.path}/Documents/plezy_downloads.db');
    AppDatabase? database;
    try {
      await legacy.parent.create();
      await legacy.writeAsBytes([11, 23, 37, 41]);
      PathProviderPlatform.instance = paths;
      final bootstrap = await AppDatabase.open(
        isTvos: false,
        preferences: prefs,
        executorFactory: (_) => NativeDatabase.memory(),
      );
      database = bootstrap.database;
      expect(paths.documentsLookups, 0);
      expect(await legacy.readAsBytes(), [11, 23, 37, 41]);
      expect(await File('${root.path}/LiveSync/plezy_downloads.db').exists(), isFalse);
    } finally {
      await database?.close();
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS && !Platform.isWindows);
}
