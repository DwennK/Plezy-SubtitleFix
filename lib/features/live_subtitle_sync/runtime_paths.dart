import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolve only bundled libraries beside this executable. No PATH lookup or
/// environment-controlled fallback to an unrelated native runtime.
class LiveSyncRuntimePaths {
  const LiveSyncRuntimePaths(this.capture, this.inference, {this.acceleratedInference});
  final String capture;
  final String inference;
  final String? acceleratedInference;

  static LiveSyncRuntimePaths? bundled() {
    final executableDirectory = p.dirname(Platform.resolvedExecutable);
    final abi = Abi.current();
    if (abi == Abi.macosArm64) {
      final directory = p.normalize(p.join(executableDirectory, '..', 'Frameworks'));
      return LiveSyncRuntimePaths(
        p.join(directory, 'liblivesync_capture_bridge.dylib'),
        p.join(directory, 'liblivesync_inference_bridge.dylib'),
      );
    }
    if (abi == Abi.windowsX64) {
      return LiveSyncRuntimePaths(
        p.join(executableDirectory, 'livesync_capture_bridge.dll'),
        p.join(executableDirectory, 'livesync_inference_bridge.dll'),
        acceleratedInference: p.join(executableDirectory, 'livesync_inference_bridge_avx2.dll'),
      );
    }
    return null;
  }
}
