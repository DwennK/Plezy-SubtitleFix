import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:plezy/features/live_subtitle_sync/model_manager.dart';

const fixture = [1, 3, 5, 7, 9, 11];

Matcher failure(ModelFailure reason) => isA<ModelException>().having((error) => error.reason, 'reason', reason);

void finish(HttpResponse response) {
  unawaited(response.close().then<void>((_) {}, onError: (Object _) {}));
}

void main() {
  late Directory directory;
  late HttpServer server;
  late IOClient client;
  late LiveSyncModel model;
  late LiveSyncModelManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('livesync-model-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = IOClient();
    model = LiveSyncModel(
      id: 'fixture',
      url: 'http://127.0.0.1:${server.port}/model?token=private-fixture',
      bytes: fixture.length,
      sha256: crypto.sha256.convert(fixture).toString(),
    );
    manager = LiveSyncModelManager(directory: directory, client: client);
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('catalog matches the reviewed native model manifest exactly', () async {
    final manifest = jsonDecode(await File('docs/live-subtitle-sync-versions.json').readAsString()) as Map;
    for (final spec in [LiveSyncModel.baseEnglish, LiveSyncModel.quantizedEnglish]) {
      final record = (manifest['models'] as List).cast<Map>().singleWhere(
        (item) => item['file'] == 'ggml-${spec.id}.bin',
      );
      expect(spec.url, record['url']);
      expect(spec.bytes, record['bytes']);
      expect(spec.sha256, record['sha256']);
    }
  });

  test('concurrent acquisition downloads once, verifies content and protects active leases', () async {
    var requests = 0;
    server.listen((request) {
      requests++;
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      request.response.contentLength = fixture.length;
      request.response.add(fixture);
      finish(request.response);
    });
    final progress = <ModelProgress>[];
    final leases = await Future.wait([manager.acquire(model, onProgress: progress.add), manager.acquire(model)]);
    expect(requests, 1);
    expect(await leases.first.file.readAsBytes(), fixture);
    expect(leases.first.file.path, leases.last.file.path);
    expect(progress.map((value) => value.phase), contains(ModelPreparationPhase.verifying));
    expect(
      progress.where((value) => value.phase == ModelPreparationPhase.downloading).last.receivedBytes,
      fixture.length,
    );
    expect(await directory.list().length, 1);
    await expectLater(manager.delete(model), throwsA(failure(ModelFailure.inUse)));
    leases.first.release();
    leases.first.release();
    await expectLater(manager.delete(model), throwsA(failure(ModelFailure.inUse)));
    leases.last.release();
    final cached = await manager.acquire(model);
    expect(requests, 1);
    cached.release();
    await manager.delete(model);
    expect(await directory.list().isEmpty, isTrue);
  });

  test('a corrupt cached model is replaced only by verified bytes', () async {
    final cached = File('${directory.path}/${model.sha256}.bin');
    await cached.writeAsBytes(List.filled(fixture.length, 0));
    final unrelated = File('${directory.path}/keep.txt');
    await unrelated.writeAsString('keep');
    server.listen((request) {
      request.response.add(fixture);
      finish(request.response);
    });
    final lease = await manager.acquire(model);
    expect(await lease.file.readAsBytes(), fixture);
    lease.release();
    await manager.delete(model);
    expect(await unrelated.readAsString(), 'keep');
  });

  test('wrong hash and oversized chunked bodies never become cached models', () async {
    var requests = 0;
    server.listen((request) {
      requests++;
      request.response.add(requests == 1 ? List.filled(fixture.length, 0) : [...fixture, 99]);
      finish(request.response);
    });
    for (var i = 0; i < 2; i++) {
      await expectLater(manager.acquire(model), throwsA(failure(ModelFailure.integrity)));
      expect(await directory.list().isEmpty, isTrue);
    }
  });

  test('short body and advertised size mismatch are rejected and cleaned up', () async {
    var requests = 0;
    server.listen((request) {
      requests++;
      if (requests == 2) request.response.contentLength = fixture.length - 1;
      request.response.add(fixture.sublist(1));
      finish(request.response);
    });
    await expectLater(manager.acquire(model), throwsA(failure(ModelFailure.integrity)));
    await expectLater(manager.acquire(model), throwsA(failure(ModelFailure.download)));
    expect(await directory.list().isEmpty, isTrue);
  });

  test('cancel interrupts a stalled real HTTP body and the same client can retry', () async {
    var requests = 0;
    final started = Completer<void>();
    server.listen((request) {
      requests++;
      if (requests == 1) {
        request.response.bufferOutput = false;
        request.response.contentLength = fixture.length;
        request.response.add([1]);
        unawaited(request.response.flush().then<void>((_) {}, onError: (Object _) {}));
      } else {
        request.response.add(fixture);
        finish(request.response);
      }
    });
    final pending = manager.acquire(
      model,
      onProgress: (progress) {
        if (progress.receivedBytes > 0 && !started.isCompleted) started.complete();
      },
    );
    final assertion = expectLater(pending, throwsA(failure(ModelFailure.cancelled)));
    await started.future;
    manager.cancel(model);
    await assertion.timeout(const Duration(seconds: 3));
    expect(await directory.list().isEmpty, isTrue);
    final lease = await manager.acquire(model);
    expect(await lease.file.readAsBytes(), fixture);
    lease.release();
  });

  test('delete cancels a pending download before removing its model', () async {
    final started = Completer<void>();
    server.listen((request) {
      request.response.bufferOutput = false;
      request.response.contentLength = fixture.length;
      request.response.add([1]);
      unawaited(request.response.flush().then<void>((_) {}, onError: (Object _) {}));
    });
    final pending = manager.acquire(
      model,
      onProgress: (progress) {
        if (progress.receivedBytes > 0 && !started.isCompleted) started.complete();
      },
    );
    final assertion = expectLater(pending, throwsA(failure(ModelFailure.cancelled)));
    await started.future;
    await manager.delete(model);
    await assertion;
    expect(await directory.list().isEmpty, isTrue);
  });

  test('idle timeout cancels stalled transport and exposes no URI or token', () async {
    manager = LiveSyncModelManager(directory: directory, client: client, idleTimeout: const Duration(milliseconds: 80));
    server.listen((request) {
      request.response.bufferOutput = false;
      request.response.contentLength = fixture.length;
      request.response.add([1]);
      unawaited(request.response.flush().then<void>((_) {}, onError: (Object _) {}));
    });
    await expectLater(manager.acquire(model), throwsA(failure(ModelFailure.timeout)));
    expect(await directory.list().isEmpty, isTrue);
    expect(const ModelException(ModelFailure.timeout).toString(), 'ModelException(timeout)');
  });

  test('invalid descriptors cannot select paths outside the model directory', () async {
    final invalid = LiveSyncModel(id: 'invalid', url: model.url, bytes: 6, sha256: '../escape');
    await expectLater(manager.acquire(invalid), throwsA(failure(ModelFailure.invalidSpec)));
    await expectLater(manager.delete(invalid), throwsA(failure(ModelFailure.invalidSpec)));
    expect(await directory.list().isEmpty, isTrue);
  });

  test('total deadline stops a slow transfer even while chunks keep arriving', () async {
    manager = LiveSyncModelManager(
      directory: directory,
      client: client,
      totalTimeout: const Duration(milliseconds: 500),
      idleTimeout: const Duration(milliseconds: 200),
    );
    final slow = LiveSyncModel(
      id: 'slow',
      url: model.url,
      bytes: 1000,
      sha256: crypto.sha256.convert(List.filled(1000, 1)).toString(),
    );
    Timer? sender;
    var chunks = 0;
    server.listen((request) {
      request.response.bufferOutput = false;
      request.response.contentLength = slow.bytes;
      sender = Timer.periodic(const Duration(milliseconds: 20), (_) {
        request.response.add([1]);
        chunks++;
        unawaited(request.response.flush().then<void>((_) {}, onError: (Object _) {}));
      });
    });
    try {
      await expectLater(manager.acquire(slow), throwsA(failure(ModelFailure.timeout)));
      expect(chunks, greaterThan(1));
      expect(await directory.list().isEmpty, isTrue);
    } finally {
      sender?.cancel();
    }
  });

  test('crash recovery removes only stale marked downloads and preserves recent or unrelated files', () async {
    final abandoned = await directory.createTemp('.livesync-model-');
    await File(
      '${abandoned.path}/owner.json',
    ).writeAsString(jsonEncode({'owner': 'plezy-livesync-model-v1', 'sha256': model.sha256}));
    await File('${abandoned.path}/download.partial').writeAsBytes([1, 2]);
    final unrelated = await directory.createTemp('.livesync-model-');
    await File(
      '${unrelated.path}/owner.json',
    ).writeAsString(jsonEncode({'owner': 'plezy-livesync-model-v1', 'sha256': model.sha256}));
    await File('${unrelated.path}/keep.txt').writeAsString('keep');
    server.listen((request) {
      request.response.add(fixture);
      finish(request.response);
    });
    final first = await manager.acquire(model);
    first.release();
    expect(await abandoned.exists(), isTrue, reason: 'recent directories must not be reclaimed');
    final recovery = LiveSyncModelManager(directory: directory, client: client, staleAfter: Duration.zero);
    final second = await recovery.acquire(model);
    second.release();
    expect(await abandoned.exists(), isFalse);
    expect(await File('${unrelated.path}/keep.txt').readAsString(), 'keep');
  });
}
