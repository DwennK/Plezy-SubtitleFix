/// Prepare the complete subtitle index and active PCM capture concurrently.
/// No inference is submitted here. Capture owns only its existing bounded ring.
///
/// The first failure cancels the sibling preparation. Both operations are joined
/// before returning, and any capture created during failure is closed before
/// propagating the error. Ownership transfers to the caller only on success.
Future<(S, C)> prepareLiveSyncInputs<S extends Object, C extends Object>({
  required Future<S> Function() loadSubtitles,
  required Future<C> Function() openCapture,
  required void Function() cancelPending,
  required Future<void> Function(C) closeCapture,
}) async {
  S? subtitles;
  C? capture;
  Object? firstError;
  StackTrace? firstStack;

  void failed(Object error, StackTrace stack) {
    if (firstError != null) return;
    firstError = error;
    firstStack = stack;
    cancelPending();
  }

  Future<void> load() async {
    try {
      subtitles = await loadSubtitles();
    } catch (error, stack) {
      failed(error, stack);
    }
  }

  Future<void> open() async {
    if (firstError != null) return;
    try {
      capture = await openCapture();
    } catch (error, stack) {
      failed(error, stack);
    }
  }

  await Future.wait([load(), open()]);
  if (firstError != null) {
    final owned = capture;
    if (owned != null) await closeCapture(owned);
    Error.throwWithStackTrace(firstError!, firstStack!);
  }
  return (subtitles!, capture!);
}
