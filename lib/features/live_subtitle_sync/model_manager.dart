import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../utils/media_server_http_client.dart';

class LiveSyncModel {
  const LiveSyncModel({required this.id, required this.url, required this.bytes, required this.sha256});

  final String id;
  final String url;
  final int bytes;
  final String sha256;

  static const baseEnglish = LiveSyncModel(
    id: 'base.en',
    url:
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin',
    bytes: 147964211,
    sha256: 'a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002',
  );
  static const quantizedEnglish = LiveSyncModel(
    id: 'base.en-q5_1',
    url:
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en-q5_1.bin',
    bytes: 59721011,
    sha256: '4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f',
  );
}

enum ModelFailure { invalidSpec, download, integrity, cancelled, timeout, storage, inUse }

class ModelException implements Exception {
  const ModelException(this.reason);
  final ModelFailure reason;

  @override
  String toString() => 'ModelException(${reason.name})';
}

enum ModelPreparationPhase { checking, downloading, verifying }

class ModelProgress {
  const ModelProgress(this.phase, this.receivedBytes, this.totalBytes);
  final ModelPreparationPhase phase;
  final int receivedBytes;
  final int totalBytes;
}

/// Keep this lease until the native inference context has been destroyed.
/// Settings cannot remove a model still held by an analysis worker.
class ModelLease {
  ModelLease._(this.file, this._release);
  final File file;
  void Function()? _release;

  void release() {
    _release?.call();
    _release = null;
  }
}

class _Preparation {
  _Preparation(int bytes) : progress = ModelProgress(ModelPreparationPhase.checking, 0, bytes);
  final abort = AbortController();
  late final _cancellation = abort.trigger.asStream().asBroadcastStream();
  final listeners = <void Function(ModelProgress)>{};
  late final Future<File> result;
  ModelProgress progress;
  bool timedOut = false;

  void check() {
    if (abort.isAborted) throw ModelException(timedOut ? ModelFailure.timeout : ModelFailure.cancelled);
  }

  void timeout() {
    timedOut = true;
    abort.abort();
  }

  void update(ModelProgress value) {
    progress = value;
    for (final listener in listeners.toList()) {
      listener(value);
    }
  }

  Future<T> interruptible<T>(Future<T> work) {
    final result = Completer<T>();
    void cancel() {
      if (!result.isCompleted) {
        result.completeError(ModelException(timedOut ? ModelFailure.timeout : ModelFailure.cancelled));
      }
    }

    final subscription = _cancellation.listen((_) => cancel());
    unawaited(
      work.then(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    if (abort.isAborted) cancel();
    return result.future.whenComplete(subscription.cancel);
  }
}

/// One application-owned instance, with a dedicated model directory in the
/// fork's Application Support directory and a borrowed HTTP client. No media
/// headers, dialogue, PCM or transcription pass through this component.
class LiveSyncModelManager {
  LiveSyncModelManager({
    required this.directory,
    required this.client,
    this.totalTimeout = const Duration(minutes: 15),
    this.idleTimeout = const Duration(seconds: 30),
    this.staleAfter = const Duration(days: 1),
  });

  final Directory directory;
  final http.Client client;
  final Duration totalTimeout;
  final Duration idleTimeout;
  final Duration staleAfter;
  final _preparations = <String, _Preparation>{};
  final _leases = <String, int>{};
  final _deleting = <String>{};
  Future<void>? _recovery;

  Future<ModelLease> acquire(LiveSyncModel model, {void Function(ModelProgress)? onProgress}) async {
    _validate(model);
    if (_deleting.contains(model.sha256)) throw const ModelException(ModelFailure.cancelled);
    final operation = _preparations.putIfAbsent(model.sha256, () {
      final operation = _Preparation(model.bytes);
      operation.result = _prepare(model, operation).whenComplete(() => _preparations.remove(model.sha256));
      return operation;
    });
    if (onProgress != null) {
      operation.listeners.add(onProgress);
      onProgress(operation.progress);
    }
    try {
      final file = await operation.result;
      operation.check();
      if (_deleting.contains(model.sha256)) throw const ModelException(ModelFailure.cancelled);
      _leases.update(model.sha256, (count) => count + 1, ifAbsent: () => 1);
      return ModelLease._(file, () {
        final count = (_leases[model.sha256] ?? 1) - 1;
        if (count == 0) {
          _leases.remove(model.sha256);
        } else {
          _leases[model.sha256] = count;
        }
      });
    } finally {
      operation.listeners.remove(onProgress);
    }
  }

  /// Cancels the shared preparation, including all callers waiting for it.
  void cancel(LiveSyncModel model) => _preparations[model.sha256]?.abort.abort();

  Future<void> delete(LiveSyncModel model) async {
    _validate(model);
    if ((_leases[model.sha256] ?? 0) > 0) throw const ModelException(ModelFailure.inUse);
    if (!_deleting.add(model.sha256)) throw const ModelException(ModelFailure.inUse);
    try {
      final operation = _preparations[model.sha256];
      if (operation != null) {
        operation.abort.abort();
        try {
          await operation.result;
        } on ModelException {
          // Preparation removes its own temporary file before completing.
        }
      }
      final file = _file(model);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      throw const ModelException(ModelFailure.storage);
    } finally {
      _deleting.remove(model.sha256);
    }
  }

  File _file(LiveSyncModel model) => File(p.join(directory.path, '${model.sha256}.bin'));

  void _validate(LiveSyncModel model) {
    final uri = Uri.tryParse(model.url);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(model.sha256) ||
        model.bytes <= 0 ||
        model.bytes > 512 * 1024 * 1024 ||
        uri == null ||
        !(uri.scheme == 'https' || (uri.scheme == 'http' && uri.host == '127.0.0.1'))) {
      throw const ModelException(ModelFailure.invalidSpec);
    }
  }

  Future<File> _prepare(LiveSyncModel model, _Preparation operation) async {
    final deadline = Timer(totalTimeout, operation.timeout);
    Directory? temporary;
    try {
      await _recoverOnce();
      final destination = _file(model);
      if (await _verifiedModel(destination.path, model.bytes, model.sha256)) {
        operation.check();
        return destination;
      }
      operation.check();
      await directory.create(recursive: true);
      temporary = await directory.createTemp('.livesync-model-');
      await File(
        p.join(temporary.path, 'owner.json'),
      ).writeAsString(jsonEncode({'owner': 'plezy-livesync-model-v1', 'sha256': model.sha256}), flush: true);
      final partial = File(p.join(temporary.path, 'download.partial'));
      final request = http.AbortableRequest('GET', Uri.parse(model.url), abortTrigger: operation.abort.trigger);
      final pending = client.send(request).then((response) async {
        if (operation.abort.isAborted) {
          await response.stream.listen(null).cancel();
          operation.check();
        }
        return response;
      });
      final response = await operation.interruptible(pending.timeout(idleTimeout));
      if (response.statusCode != 200 || (response.contentLength != null && response.contentLength != model.bytes)) {
        await response.stream.listen(null).cancel();
        throw const ModelException(ModelFailure.download);
      }
      final iterator = StreamIterator(response.stream);
      RandomAccessFile? output;
      var received = 0;
      try {
        output = await partial.open(mode: FileMode.write);
        while (await operation.interruptible(iterator.moveNext().timeout(idleTimeout))) {
          operation.check();
          final chunk = iterator.current;
          if (received + chunk.length > model.bytes) throw const ModelException(ModelFailure.integrity);
          await output.writeFrom(chunk);
          received += chunk.length;
          operation.update(ModelProgress(ModelPreparationPhase.downloading, received, model.bytes));
        }
        await output.flush();
      } finally {
        await iterator.cancel();
        await output?.close();
      }
      operation.check();
      operation.update(ModelProgress(ModelPreparationPhase.verifying, received, model.bytes));
      if (received != model.bytes || !await _verifiedModel(partial.path, model.bytes, model.sha256)) {
        throw const ModelException(ModelFailure.integrity);
      }
      operation.check();
      return await partial.rename(destination.path);
    } on ModelException {
      rethrow;
    } on TimeoutException {
      operation.timeout();
      throw const ModelException(ModelFailure.timeout);
    } on FileSystemException {
      throw const ModelException(ModelFailure.storage);
    } catch (_) {
      operation.check();
      throw const ModelException(ModelFailure.download);
    } finally {
      deadline.cancel();
      try {
        if (temporary != null && await temporary.exists()) await temporary.delete(recursive: true);
      } on FileSystemException {
        throw const ModelException(ModelFailure.storage);
      }
    }
  }

  Future<void> _recoverOnce() async {
    final recovery = _recovery ??= _removeStaleDownloads();
    try {
      await recovery;
    } catch (_) {
      if (identical(_recovery, recovery)) _recovery = null;
      rethrow;
    }
  }

  Future<void> _removeStaleDownloads() async {
    if (!await directory.exists()) return;
    final cutoff = DateTime.now().subtract(staleAfter);
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! Directory || !p.basename(entry.path).startsWith('.livesync-model-')) continue;
      if ((await entry.stat()).modified.isAfter(cutoff)) continue;
      final owner = File(p.join(entry.path, 'owner.json'));
      if (await FileSystemEntity.type(owner.path, followLinks: false) != FileSystemEntityType.file ||
          await owner.length() > 1024) {
        continue;
      }
      Object? marker;
      try {
        marker = jsonDecode(await owner.readAsString());
      } on FormatException {
        continue;
      }
      if (marker is! Map ||
          marker['owner'] != 'plezy-livesync-model-v1' ||
          marker['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(marker['sha256'] as String)) {
        continue;
      }
      // A marker does not authorize deleting unrelated files or nested trees.
      var ownedOnly = true;
      await for (final child in entry.list(followLinks: false)) {
        if (child is! File || !{'owner.json', 'download.partial'}.contains(p.basename(child.path))) {
          ownedOnly = false;
          break;
        }
      }
      if (ownedOnly) await entry.delete(recursive: true);
    }
  }
}

// Hash in a background isolate, with streaming input rather than loading a
// 148 MB model into the UI isolate. This component is desktop-only.
Future<bool> _verifiedModel(String path, int bytes, String expected) => Isolate.run(() async {
  final file = File(path);
  if (!await file.exists() || await file.length() != bytes) return false;
  return (await crypto.sha256.bind(file.openRead()).first).toString() == expected;
});
