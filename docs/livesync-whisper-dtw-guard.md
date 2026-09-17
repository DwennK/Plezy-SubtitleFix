# Whisper DTW short-tail guard

The native drift probe using the installed macOS 3947d586 inference library
aborted inside Whisper's `median_filter`. Fifteen fixed public audio windows
and two subsequent complete probes did not reproduce the crash. Its exact
audio window and assertion are therefore not identified.

At pinned Whisper revision `927cfce34f31707e17f2bff35c349632fb9e2c3a`, DTW passes
`n_frames / 2` audio tokens into a width-seven median filter. The filter asserts
that its width is strictly smaller than the audio axis. Internal decoded tails
can be short even when the submitted PCM window spans several seconds.

The generated translation unit returns before DTW allocation for unsupported
tails of at most fifteen frames. It keeps recognition and other segments,
but invalidates the affected tokens' DTW timestamps (`-1`). Existing inference
and alignment checks reject those tokens as timing evidence. No audio is
padded and no timestamp is inferred. Supported tails use the original code.

The patch helper checks the full pinned source hash, normalizing only Git's
CRLF conversion, and refuses in-place writes. CMake compiles a generated copy;
the upstream checkout stays untouched. Runtime provenance includes the helper.

## Validation and limits

- CTest calls the actual patched private DTW function for 0–15 frame tails,
  checking recognition and earlier/later segment retention.
- The original filter still operates on the first supported eight-token axis.
- A separate opt-in child process calls the unmodified filter with seven audio
  tokens and confirms SIGABRT at its width assertion. This demonstrates that
  precondition, not the exact original audio incident.
- The patch integration test checks source drift, repeat generation, CRLF and
  protection of the original source.
- Real public JFK inference retains supported token timestamps and recognition.

This is a native crash guard. It does not establish drift accuracy, automatic
scene-gap detection, audible Mentalist alignment, or product acceptance.
