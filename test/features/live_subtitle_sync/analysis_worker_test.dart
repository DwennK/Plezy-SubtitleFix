import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/features/live_subtitle_sync/analysis_worker.dart';
import 'package:plezy/features/live_subtitle_sync/model_manager.dart';
import 'package:plezy/features/live_subtitle_sync/native_bindings.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('livesync/test-player');

  test('native startup rejection completes and releases the model instead of waiting forever', () async {
    final directory = await Directory.systemTemp.createTemp('livesync-worker-rejected-');
    final client = http.Client();
    final model = LiveSyncModel(
      id: 'fixture',
      url: 'https://example.invalid/model',
      bytes: 4,
      sha256: crypto.sha256.convert([1, 2, 3, 4]).toString(),
    );
    await File('${directory.path}/${model.sha256}.bin').writeAsBytes([1, 2, 3, 4]);
    final manager = LiveSyncModelManager(directory: directory, client: client);
    // Rejected inside the real analysis isolate, before any native pointer is
    // dereferenced. This exercises its four-field error reply, not a platform
    // exception raised on the UI isolate before the open request.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => <int>[]);
    try {
      final lease = await manager.acquire(model);
      await expectLater(
        LiveSyncAnalysisWorker.start(
          playerChannel: channel,
          lease: lease,
          captureLibrary: '/not-loaded',
          inferenceLibrary: '/not-loaded',
          generation: 1,
        ).timeout(const Duration(seconds: 5)),
        throwsA(
          isA<NativeSyncException>()
              .having((error) => error.reason, 'reason', NativeSyncFailure.incompatibleAbi)
              .having((error) => error.nativeStatus, 'native status', isNull),
        ),
      );
      await manager.delete(model);
      expect(await directory.list().isEmpty, isTrue);
    } finally {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      client.close();
      await directory.delete(recursive: true);
    }
  });

  test('missing native player closes the prepared isolate and releases its model lease', () async {
    final directory = await Directory.systemTemp.createTemp('livesync-worker-');
    final client = http.Client();
    final model = LiveSyncModel(
      id: 'fixture',
      url: 'https://example.invalid/model',
      bytes: 4,
      sha256: crypto.sha256.convert([1, 2, 3, 4]).toString(),
    );
    await File('${directory.path}/${model.sha256}.bin').writeAsBytes([1, 2, 3, 4]);
    final manager = LiveSyncModelManager(directory: directory, client: client);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'NOT_INITIALIZED', message: 'Do not leak native path or source details');
    });
    try {
      final lease = await manager.acquire(model);
      await expectLater(
        LiveSyncAnalysisWorker.start(
          playerChannel: channel,
          lease: lease,
          captureLibrary: '/not-loaded',
          inferenceLibrary: '/not-loaded',
          generation: 1,
        ),
        throwsA(
          isA<NativeSyncException>().having(
            (error) => error.toString(),
            'sanitized error',
            'NativeSyncException(captureUnavailable)',
          ),
        ),
      );
      // Fails with ModelFailure.inUse if startup abandoned its lease.
      await manager.delete(model);
      expect(await directory.list().isEmpty, isTrue);
    } finally {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      client.close();
      await directory.delete(recursive: true);
    }
  });
}
