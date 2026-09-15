import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/update_service.dart';

void main() {
  test('desktop fork cannot enable the official updater through inherited build flags', () async {
    expect(UpdateService.isUpdateCheckEnabled, isFalse);
    expect(UpdateService.isUpdateCheckAvailable, isFalse);
    expect(UpdateService.useNativeUpdater, isFalse);
    // This must return without invoking any native plugin, even when CI sets
    // ENABLE_UPDATE_CHECK=true as the official release workflow does.
    await UpdateService.initNativeUpdater();
  }, skip: !Platform.isMacOS && !Platform.isWindows);
}
