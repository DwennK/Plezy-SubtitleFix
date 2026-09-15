// Explicit network integration probe; not part of the default unit test tree.
// flutter test --no-pub tool/livesync_model_probe_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:plezy/features/live_subtitle_sync/model_manager.dart';

class _CountingClient extends http.BaseClient {
  final _inner = IOClient();
  var requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests++;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

void main() {
  test('download, hash, reuse and delete the real pinned quantized English model', () async {
    final directory = await Directory.systemTemp.createTemp('livesync-real-model-');
    final client = _CountingClient();
    final manager = LiveSyncModelManager(directory: directory, client: client);
    const model = LiveSyncModel.quantizedEnglish;
    ModelLease? first;
    ModelLease? second;
    final watch = Stopwatch()..start();
    var received = 0;
    try {
      first = await manager.acquire(
        model,
        onProgress: (progress) {
          expect(progress.receivedBytes, greaterThanOrEqualTo(received));
          expect(progress.receivedBytes, lessThanOrEqualTo(model.bytes));
          received = progress.receivedBytes;
        },
      );
      final downloadSeconds = watch.elapsedMilliseconds / 1000;
      expect(received, model.bytes);
      expect(await first.file.length(), model.bytes);
      final actualHash = (await crypto.sha256.bind(first.file.openRead()).first).toString();
      expect(actualHash, model.sha256);
      first.release();
      second = await manager.acquire(model);
      expect(client.requests, 1);
      second.release();
      await manager.delete(model);
      expect(await directory.list().isEmpty, isTrue);
      final report = File('build/livesync/evidence/model-download.json');
      await report.parent.create(recursive: true);
      final evidence = {
        'kind': 'real-pinned-model-download-through-dart-manager',
        'model': model.id,
        'bytes': model.bytes,
        'sha256': actualHash,
        'downloadAndVerificationSeconds': downloadSeconds,
        'modelRequests': client.requests,
        'cachedReuseVerified': true,
        'deletionVerified': true,
        'productionUiValidated': false,
      };
      await report.writeAsString('${const JsonEncoder.withIndent('  ').convert(evidence)}\n');
    } finally {
      first?.release();
      second?.release();
      client.close();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 16)));
}
