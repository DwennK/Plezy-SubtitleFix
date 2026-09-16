/// The capability check runs in portable native code before this selection.
/// Ineligible CPUs must never even load the accelerated DLL: its static
/// initializers may already contain instructions those processors cannot run.
({T value, String backend}) openCpuInference<T>({
  required bool avx2Supported,
  required T Function() openPortable,
  required T Function() openAvx2,
}) {
  if (avx2Supported) {
    try {
      return (value: openAvx2(), backend: 'avx2-cpu');
    } catch (_) {
      // Missing DLL, loader failure or ABI mismatch: retain the CPU fallback.
    }
  }
  return (value: openPortable(), backend: 'portable-cpu');
}
