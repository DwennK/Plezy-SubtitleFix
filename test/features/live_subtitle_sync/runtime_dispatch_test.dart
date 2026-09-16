import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/features/live_subtitle_sync/runtime_dispatch.dart';

void main() {
  test('unsupported CPU never loads accelerated code, including initializers', () {
    final loaded = <String>[];
    final runtime = openCpuInference(
      avx2Supported: false,
      openPortable: () {
        loaded.add('portable');
        return 1;
      },
      openAvx2: () {
        loaded.add('avx2');
        throw StateError('must not execute');
      },
    );
    expect(loaded, ['portable']);
    expect(runtime.backend, 'portable-cpu');
    expect(runtime.value, 1);
  });

  test('eligible CPU loads the checked AVX2 library without a second model', () {
    final runtime = openCpuInference(
      avx2Supported: true,
      openPortable: () => throw StateError('unnecessary portable load'),
      openAvx2: () => 2,
    );
    expect(runtime.backend, 'avx2-cpu');
    expect(runtime.value, 2);
  });

  test('a missing or incompatible accelerated library falls back to portable', () {
    final runtime = openCpuInference(
      avx2Supported: true,
      openPortable: () => 1,
      openAvx2: () => throw ArgumentError('invalid library'),
    );
    expect(runtime.backend, 'portable-cpu');
    expect(runtime.value, 1);
  });

  test('a failure of both libraries remains a failure', () {
    expect(
      () => openCpuInference(
        avx2Supported: true,
        openPortable: () => throw StateError('portable unavailable'),
        openAvx2: () => throw ArgumentError('accelerated unavailable'),
      ),
      throwsStateError,
    );
  });
}
