import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'audio_activity.dart';
import 'runtime_dispatch.dart';

// Handwritten capture ABI v1 and inference ABI v2 declarations, checked against native sizeof before use.
// Every operation, including creation/destruction, belongs to the serialized
// analysis isolate. Do not import this module from UI widgets.
final class _MpvApi extends Struct {
  @Uint32()
  external int version;
  external Pointer<Void> getProperty;
  external Pointer<Void> setProperty;
  external Pointer<Void> freeNode;
  external Pointer<Void> waitEvent;
  external Pointer<Void> destroy;
}

final class _CaptureInfo extends Struct {
  @Uint64()
  external int generation;
  @Uint64()
  external int continuity;
  @Uint64()
  external int samples;
  @Uint32()
  external int state;
}

final class _WindowInfo extends Struct {
  @Uint64()
  external int generation;
  @Uint64()
  external int continuity;
  @Double()
  external double mediaStart;
  @Double()
  external double mediaSecondsPerSample;
}

final class _Token extends Struct {
  @Double()
  external double start;
  @Double()
  external double end;
  @Float()
  external double score;
  @Uint32()
  external int hasTimestamp;
  @Uint32()
  external int speechSupport;
  @Uint32()
  external int textOffset;
  @Uint32()
  external int textLength;
}

final class _Segment extends Struct {
  @Double()
  external double start;
  @Double()
  external double end;
  @Uint32()
  external int textOffset;
  @Uint32()
  external int textLength;
  @Uint32()
  external int tokenOffset;
  @Uint32()
  external int tokenCount;
}

final class _Result extends Struct {
  @Uint64()
  external int generation;
  @Uint64()
  external int continuity;
  @Double()
  external double elapsed;
  @Uint32()
  external int status;
  @Uint32()
  external int segmentCount;
  @Uint32()
  external int tokenCount;
  @Uint32()
  external int textBytes;
  @Array(64)
  external Array<_Segment> segments;
  @Array(512)
  external Array<_Token> tokens;
  @Array(8192)
  external Array<Uint8> text;
}

enum NativeSyncFailure { libraryUnavailable, incompatibleAbi, captureUnavailable, inferenceUnavailable, invalidOutput }

class NativeSyncException implements Exception {
  const NativeSyncException(this.reason, {this.nativeStatus});
  final NativeSyncFailure reason;

  /// Numeric ABI result only; never a native path or arbitrary error message.
  final int? nativeStatus;
  @override
  String toString() => 'NativeSyncException(${reason.name})';
}

enum NativeSpeechSupport { unknown, supported, unsupported }

class NativeTranscriptToken {
  const NativeTranscriptToken(
    this.text,
    this.start,
    this.end,
    this.score,
    this.hasTimestamp, {
    this.speechSupport = NativeSpeechSupport.unknown,
  });
  final String text;
  final double start;
  final double end;
  final double score;
  final bool hasTimestamp;
  final NativeSpeechSupport speechSupport;
}

class NativeTranscriptSegment {
  NativeTranscriptSegment(this.text, this.start, this.end, List<NativeTranscriptToken> tokens)
    : tokens = List.unmodifiable(tokens);
  final String text;
  final double start;
  final double end;
  final List<NativeTranscriptToken> tokens;
}

class NativeTranscript {
  NativeTranscript(
    this.generation,
    this.continuity,
    this.windowStart,
    this.windowEnd,
    this.elapsed,
    List<NativeTranscriptSegment> segments, {
    this.validPrefixOnly = false,
  }) : segments = List.unmodifiable(segments);
  final int generation;
  final int continuity;
  final double windowStart;
  final double windowEnd;
  final double elapsed;
  final List<NativeTranscriptSegment> segments;
  final bool validPrefixOnly;
}

/// An owned weak client supplied by the *active* platform player. The function
/// addresses refer to that same mpv image, including Apple's static framework.
/// Never deserialize addresses from files, network, subtitles or user input.
class NativeMpvClient {
  NativeMpvClient(List<int> addresses) : addresses = List.unmodifiable(addresses) {
    if (addresses.length != 6 || addresses.any((value) => value <= 0)) {
      throw const NativeSyncException(NativeSyncFailure.incompatibleAbi);
    }
  }
  final List<int> addresses;
  bool _owned = true;
  void release() {
    if (!_owned) return;
    _owned = false;
    Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(
      addresses[5],
    ).asFunction<void Function(Pointer<Void>)>()(Pointer.fromAddress(addresses[0]));
  }
}

class NativeCaptureStatus {
  const NativeCaptureStatus(this.generation, this.continuity, this.samples, this.state);
  final int generation;
  final int continuity;
  final int samples;

  /// 0 PCM available, 1 waiting, 2 invalid packet, 3 unsupported layout, 4 stopped.
  final int state;
}

/// Bounded native session. No PCM/transcript logging, persistence or networking.
/// The model lease must outlive [close]. The caller must never kill its owning
/// isolate before close has joined both native threads.
class NativeLiveSyncEngine {
  NativeLiveSyncEngine._(this._captureLibrary, this._inferenceLibrary, this.inferenceBackend);
  final DynamicLibrary _captureLibrary;
  final DynamicLibrary _inferenceLibrary;
  final String inferenceBackend;
  Pointer<Void> _capture = nullptr;
  Pointer<Void> _inference = nullptr;
  Pointer<Float> _samples = nullptr;
  Pointer<_CaptureInfo> _info = nullptr;
  Pointer<_WindowInfo> _window = nullptr;
  Pointer<_Result> _result = nullptr;
  int _generation = 0;
  int _continuity = -1;
  double _submittedStart = 0;
  double _submittedEnd = 0;
  bool _pending = false;
  bool _closed = false;
  final _voiceActivity = VoiceActivityDetector();

  late final _captureDestroy = _captureLibrary
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('ls_capture_destroy');
  late final _captureReset = _captureLibrary
      .lookupFunction<Int32 Function(Pointer<Void>, Uint64), int Function(Pointer<Void>, int)>('ls_capture_reset');
  late final _captureInfo = _captureLibrary
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<_CaptureInfo>, Size),
        int Function(Pointer<Void>, Pointer<_CaptureInfo>, int)
      >('ls_capture_get_info');
  late final _snapshot = _captureLibrary
      .lookupFunction<
        Size Function(Pointer<Void>, Double, Pointer<Float>, Size, Pointer<_WindowInfo>),
        int Function(Pointer<Void>, double, Pointer<Float>, int, Pointer<_WindowInfo>)
      >('ls_capture_snapshot');
  late final _inferenceDestroy = _inferenceLibrary
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('ls_inference_destroy');
  late final _inferenceReset = _inferenceLibrary
      .lookupFunction<Int32 Function(Pointer<Void>, Uint64, Uint64), int Function(Pointer<Void>, int, int)>(
        'ls_inference_reset',
      );
  late final _submit = _inferenceLibrary
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint64, Uint64, Double, Double, Pointer<Float>, Size),
        int Function(Pointer<Void>, int, int, double, double, Pointer<Float>, int)
      >('ls_inference_submit');
  late final _take = _inferenceLibrary
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<_Result>, Size),
        int Function(Pointer<Void>, Pointer<_Result>, int)
      >('ls_inference_take_result');

  static NativeLiveSyncEngine open({
    required NativeMpvClient client,
    required String captureLibrary,
    required String inferenceLibrary,
    String? acceleratedInferenceLibrary,
    required String modelPath,
    required int generation,
    int threads = 2,
  }) {
    NativeLiveSyncEngine? engine;
    Pointer<_MpvApi> api = nullptr;
    Pointer<Utf8> path = nullptr;
    try {
      if (!client._owned || generation <= 0 || sizeOf<IntPtr>() != 8 || modelPath.contains('\u0000')) {
        throw const NativeSyncException(NativeSyncFailure.incompatibleAbi);
      }
      final captureDll = DynamicLibrary.open(captureLibrary);
      var avx2Supported = false;
      if (Abi.current() == Abi.windowsX64 && acceleratedInferenceLibrary != null) {
        try {
          avx2Supported =
              captureDll.lookupFunction<Uint32 Function(), int Function()>('ls_capture_cpu_features')() & 1 != 0;
        } catch (_) {
          // Older capture runtimes do not authorize accelerated code.
        }
      }
      final runtime = openCpuInference(
        avx2Supported: avx2Supported,
        openPortable: () => _openInferenceLibrary(inferenceLibrary),
        openAvx2: () => _openInferenceLibrary(acceleratedInferenceLibrary!),
      );
      engine = NativeLiveSyncEngine._(captureDll, runtime.value, runtime.backend);
      final capture = engine._captureLibrary;
      final inference = engine._inferenceLibrary;
      if (capture.lookupFunction<Uint32 Function(), int Function()>('ls_capture_abi_version')() != 1 ||
          inference.lookupFunction<Uint32 Function(), int Function()>('ls_inference_abi_version')() != 2 ||
          capture.lookupFunction<Size Function(), int Function()>('ls_capture_api_size')() != sizeOf<_MpvApi>() ||
          capture.lookupFunction<Size Function(), int Function()>('ls_capture_info_size')() != sizeOf<_CaptureInfo>() ||
          inference.lookupFunction<Size Function(), int Function()>('ls_inference_result_size')() !=
              sizeOf<_Result>()) {
        throw const NativeSyncException(NativeSyncFailure.incompatibleAbi);
      }
      // Resolve every symbol before accepting ownership or starting capture.
      engine._captureDestroy;
      engine._captureReset;
      engine._captureInfo;
      engine._snapshot;
      engine._inferenceDestroy;
      engine._inferenceReset;
      engine._submit;
      engine._take;
      engine._samples = calloc<Float>(240000);
      engine._info = calloc<_CaptureInfo>();
      engine._window = calloc<_WindowInfo>();
      engine._result = calloc<_Result>();
      api = calloc<_MpvApi>();
      api.ref
        ..version = 1
        ..getProperty = Pointer.fromAddress(client.addresses[1])
        ..setProperty = Pointer.fromAddress(client.addresses[2])
        ..freeNode = Pointer.fromAddress(client.addresses[3])
        ..waitEvent = Pointer.fromAddress(client.addresses[4])
        ..destroy = Pointer.fromAddress(client.addresses[5]);
      engine._capture = capture
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<_MpvApi>, Uint64),
            Pointer<Void> Function(Pointer<Void>, Pointer<_MpvApi>, int)
          >('ls_capture_create')(Pointer.fromAddress(client.addresses[0]), api, generation);
      if (engine._capture == nullptr) throw const NativeSyncException(NativeSyncFailure.captureUnavailable);
      client._owned = false;
      path = modelPath.toNativeUtf8();
      engine._inference = inference
          .lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Int32), Pointer<Void> Function(Pointer<Utf8>, int)>(
            'ls_inference_create',
          )(path, threads.clamp(1, 4));
      if (engine._inference == nullptr) throw const NativeSyncException(NativeSyncFailure.inferenceUnavailable);
      engine._generation = generation;
      return engine;
    } catch (error) {
      engine?.close();
      client.release();
      if (error is NativeSyncException) rethrow;
      throw const NativeSyncException(NativeSyncFailure.libraryUnavailable);
    } finally {
      calloc.free(api);
      calloc.free(path);
    }
  }

  static DynamicLibrary _openInferenceLibrary(String path) {
    final library = DynamicLibrary.open(path);
    if (library.lookupFunction<Uint32 Function(), int Function()>('ls_inference_abi_version')() != 2 ||
        library.lookupFunction<Size Function(), int Function()>('ls_inference_result_size')() != sizeOf<_Result>()) {
      throw const NativeSyncException(NativeSyncFailure.incompatibleAbi);
    }
    for (final symbol in [
      'ls_inference_create',
      'ls_inference_destroy',
      'ls_inference_reset',
      'ls_inference_submit',
      'ls_inference_take_result',
    ]) {
      library.lookup<Void>(symbol);
    }
    return library;
  }

  NativeCaptureStatus status() {
    if (_closed || _captureInfo(_capture, _info, sizeOf<_CaptureInfo>()) != 0) {
      throw const NativeSyncException(NativeSyncFailure.captureUnavailable);
    }
    final value = _info.ref;
    if (value.continuity != _continuity || value.state == 4) {
      _continuity = value.continuity;
      _pending = false;
      _inferenceReset(_inference, _generation, _continuity);
    }
    return NativeCaptureStatus(value.generation, value.continuity, value.samples, value.state);
  }

  void reset(int generation) {
    if (_closed || generation <= _generation || _captureReset(_capture, generation) != 0) {
      throw const NativeSyncException(NativeSyncFailure.captureUnavailable);
    }
    _generation = generation;
    _continuity = -1;
    _pending = false;
    _voiceActivity.clear();
    _inferenceReset(_inference, generation, 0);
  }

  AudioActivity? activity() {
    final current = status();
    if (current.state != 0 || current.generation != _generation) return null;
    // Runs on the serialized analysis isolate. Reuse the existing temporary
    // allocation, return only aggregate timing, then erase the copied PCM.
    final count = _snapshot(_capture, 2, _samples, 32000, _window);
    try {
      if (count == 0 ||
          count > 32000 ||
          _window.ref.generation != _generation ||
          _window.ref.continuity != _continuity) {
        return null;
      }
      return _voiceActivity.observe(
        _samples.asTypedList(count),
        generation: _generation,
        continuity: _continuity,
        start: _window.ref.mediaStart,
        secondsPerSample: _window.ref.mediaSecondsPerSample,
      );
    } finally {
      _samples.asTypedList(32000).fillRange(0, 32000, 0);
    }
  }

  bool submitRecent({double seconds = 12}) {
    final current = status();
    if (_pending || current.state != 0 || current.generation != _generation) return false;
    final count = _snapshot(_capture, seconds.clamp(8, 15), _samples, 240000, _window);
    try {
      if (count < 128000 || count > 240000 || _window.ref.generation != _generation) return false;
      if (_window.ref.continuity != _continuity) {
        _continuity = _window.ref.continuity;
        _inferenceReset(_inference, _generation, _continuity);
      }
      final accepted = _submit(
        _inference,
        _generation,
        _continuity,
        _window.ref.mediaStart,
        _window.ref.mediaSecondsPerSample,
        _samples,
        count,
      );
      if (accepted < 0) throw const NativeSyncException(NativeSyncFailure.inferenceUnavailable);
      if (accepted == 0) return false;
      _submittedStart = _window.ref.mediaStart;
      _submittedEnd = _submittedStart + count * _window.ref.mediaSecondsPerSample;
      _pending = true;
      return true;
    } finally {
      _samples.asTypedList(240000).fillRange(0, 240000, 0);
    }
  }

  NativeTranscript? takeResult() {
    final current = status();
    if (current.state == 4 || !_pending) return null;
    final code = _take(_inference, _result, sizeOf<_Result>());
    if (code == 0) return null;
    _pending = false;
    if (code != 1) throw const NativeSyncException(NativeSyncFailure.invalidOutput);
    try {
      final value = _result.ref;
      if (value.generation != _generation || value.continuity != _continuity) return null;
      if (value.status != 0 && value.status != 5) {
        throw NativeSyncException(NativeSyncFailure.inferenceUnavailable, nativeStatus: value.status);
      }
      if ((value.status == 5 && value.segmentCount == 0) ||
          value.segmentCount > 64 ||
          value.tokenCount > 512 ||
          value.textBytes > 8192 ||
          !value.elapsed.isFinite ||
          value.elapsed < 0) {
        throw const NativeSyncException(NativeSyncFailure.invalidOutput);
      }
      String text(int offset, int length) {
        if (offset > value.textBytes || length > value.textBytes - offset) {
          throw const NativeSyncException(NativeSyncFailure.invalidOutput);
        }
        return utf8.decode(List.generate(length, (i) => value.text[offset + i]));
      }

      bool timeValid(double start, double end) =>
          start.isFinite &&
          end.isFinite &&
          end >= start &&
          start >= _submittedStart - 0.02 &&
          end <= _submittedEnd + 0.32;
      final segments = <NativeTranscriptSegment>[];
      for (var s = 0; s < value.segmentCount; s++) {
        final segment = value.segments[s];
        if (!timeValid(segment.start, segment.end) ||
            segment.tokenOffset > value.tokenCount ||
            segment.tokenCount > value.tokenCount - segment.tokenOffset) {
          throw const NativeSyncException(NativeSyncFailure.invalidOutput);
        }
        final tokens = <NativeTranscriptToken>[];
        for (var t = 0; t < segment.tokenCount; t++) {
          final token = value.tokens[segment.tokenOffset + t];
          if (!token.score.isFinite ||
              token.score < 0 ||
              token.score > 1 ||
              token.hasTimestamp > 1 ||
              token.speechSupport > 2 ||
              (token.hasTimestamp == 1 && !timeValid(token.start, token.end))) {
            throw const NativeSyncException(NativeSyncFailure.invalidOutput);
          }
          tokens.add(
            NativeTranscriptToken(
              text(token.textOffset, token.textLength),
              token.start,
              token.end,
              token.score,
              token.hasTimestamp == 1,
              speechSupport: NativeSpeechSupport.values[token.speechSupport],
            ),
          );
        }
        segments.add(
          NativeTranscriptSegment(text(segment.textOffset, segment.textLength), segment.start, segment.end, tokens),
        );
      }
      return NativeTranscript(
        value.generation,
        value.continuity,
        _submittedStart,
        _submittedEnd,
        value.elapsed,
        segments,
        validPrefixOnly: value.status == 5,
      );
    } on FormatException {
      throw const NativeSyncException(NativeSyncFailure.invalidOutput);
    } finally {
      _result.cast<Uint8>().asTypedList(sizeOf<_Result>()).fillRange(0, sizeOf<_Result>(), 0);
    }
  }

  void close() {
    _voiceActivity.clear();
    if (_closed) return;
    _closed = true;
    if (_capture != nullptr) _captureDestroy(_capture);
    if (_inference != nullptr) _inferenceDestroy(_inference);
    if (_samples != nullptr) _samples.asTypedList(240000).fillRange(0, 240000, 0);
    if (_result != nullptr) _result.cast<Uint8>().asTypedList(sizeOf<_Result>()).fillRange(0, sizeOf<_Result>(), 0);
    calloc.free(_samples);
    calloc.free(_info);
    calloc.free(_window);
    calloc.free(_result);
    _capture = nullptr;
    _inference = nullptr;
  }
}
