import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'model_manager.dart';
import 'native_bindings.dart';
import 'audio_activity.dart';

/// Main-isolate control port. Creation, PCM access, inference and thread joins
/// run in the analysis isolate. A verified model lease is held until close has
/// acknowledged native teardown. Never kill this isolate to cancel inference.
class LiveSyncAnalysisWorker {
  LiveSyncAnalysisWorker._(this._lease);
  final ModelLease _lease;
  final _replies = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  late final SendPort _commands;
  int _nextId = 0;
  late final String inferenceBackend;
  bool _closing = false;
  Future<void>? _closeFuture;

  static Future<LiveSyncAnalysisWorker> start({
    required MethodChannel playerChannel,
    required ModelLease lease,
    required String captureLibrary,
    required String inferenceLibrary,
    String? acceleratedInferenceLibrary,
    required int generation,
  }) async {
    final worker = LiveSyncAnalysisWorker._(lease);
    worker._replies.listen((message) {
      if (message is SendPort) {
        worker._ready.complete(message);
      } else if (message is List && message.length == 3 && message[0] is int) {
        final reply = worker._pending.remove(message[0]);
        if (message[1] == true) {
          reply?.complete(message[2]);
        } else {
          reply?.completeError(NativeSyncException(message[2] as NativeSyncFailure));
        }
      }
    });
    try {
      // Prepare the receiver before the native player transfers client ownership.
      await Isolate.spawn(_runAnalysis, worker._replies.sendPort, debugName: 'Live subtitle sync');
      worker._commands = await worker._ready.future;
      final addresses = await playerChannel.invokeListMethod<int>('createLiveSyncClient');
      if (addresses == null) throw const NativeSyncException(NativeSyncFailure.captureUnavailable);
      worker.inferenceBackend =
          (await worker._request('open', [
                addresses,
                captureLibrary,
                inferenceLibrary,
                lease.file.path,
                generation,
                acceleratedInferenceLibrary,
              ]))!
              as String;
      return worker;
    } catch (error) {
      // If spawning itself failed, there is no native client or model context.
      if (worker._ready.isCompleted) {
        await worker.close();
      } else {
        worker._replies.close();
        lease.release();
      }
      if (error is NativeSyncException) rethrow;
      throw const NativeSyncException(NativeSyncFailure.captureUnavailable);
    }
  }

  Future<Object?> _request(String operation, Object? payload) {
    final reply = Completer<Object?>();
    final id = ++_nextId;
    _pending[id] = reply;
    _commands.send([id, operation, payload]);
    return reply.future;
  }

  void _checkOpen() {
    if (_closing) throw const NativeSyncException(NativeSyncFailure.captureUnavailable);
  }

  Future<NativeCaptureStatus> status() async {
    _checkOpen();
    return (await _request('status', null))! as NativeCaptureStatus;
  }

  Future<bool> submitRecent({double seconds = 12}) async {
    _checkOpen();
    return (await _request('submit', seconds))! as bool;
  }

  Future<AudioActivity?> activity() async {
    _checkOpen();
    return await _request('activity', null) as AudioActivity?;
  }

  Future<NativeTranscript?> takeResult() async {
    _checkOpen();
    return await _request('take', null) as NativeTranscript?;
  }

  Future<void> reset(int generation) async {
    _checkOpen();
    await _request('reset', generation);
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await _request('close', null);
    _replies.close();
    _lease.release();
  }
}

void _runAnalysis(SendPort replies) {
  final commands = ReceivePort();
  NativeLiveSyncEngine? engine;
  replies.send(commands.sendPort);
  commands.listen((message) {
    final values = message as List;
    final id = values[0] as int;
    final operation = values[1] as String;
    final payload = values[2];
    try {
      Object? result;
      switch (operation) {
        case 'open':
          final args = payload as List;
          final client = NativeMpvClient((args[0] as List).cast<int>());
          if (engine != null) {
            client.release();
            throw const NativeSyncException(NativeSyncFailure.captureUnavailable);
          }
          engine = NativeLiveSyncEngine.open(
            client: client,
            captureLibrary: args[1] as String,
            inferenceLibrary: args[2] as String,
            modelPath: args[3] as String,
            generation: args[4] as int,
            acceleratedInferenceLibrary: args[5] as String?,
          );
          result = engine!.inferenceBackend;
        case 'status':
          result = engine!.status();
        case 'submit':
          result = engine!.submitRecent(seconds: payload as double);
        case 'activity':
          result = engine!.activity();
        case 'take':
          result = engine!.takeResult();
        case 'reset':
          engine!.reset(payload as int);
        case 'close':
          engine?.close();
          engine = null;
          commands.close();
        default:
          throw const NativeSyncException(NativeSyncFailure.incompatibleAbi);
      }
      replies.send([id, true, result]);
    } catch (error) {
      // Do not send native paths, dialogue, PCM or arbitrary exception messages
      // back to the UI/error reporter. Explicit typed reasons only.
      replies.send([id, false, error is NativeSyncException ? error.reason : NativeSyncFailure.invalidOutput]);
    }
  });
}
