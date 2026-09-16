# Native feasibility gate

This is an in-progress integration, **not a shipping LiveSync backend**.

`patches/0001-bounded-timestamped-pcm-tap.patch` applies after the exact Plezy
mpv-build patch series in the versions manifest. It changes no Flutter engine
code. Only the Apple and Windows series include it. Other platforms remain on
the unmodified native dependency.

## Private transport version 1

- Set `livesync-enabled=yes` after an audio chain exists with a PCM input format.
  SPDIF passthrough is rejected. A newly created audio chain starts disabled.
- Poll `livesync-pcm` as a node on a worker. Do **not** observe this property:
  reading drains the queue. Use one consumer per player.
- The map contains `version`, `epoch`, `dropped`, `frames`. Each frame contains
  `pts` (media seconds), `speed` (sample duration multiplier), `rate`, `channels`,
  `samples`, `planes`, mpv sample `format`, and `pcm` bytes. Planes are contiguous
  in the payload. Formats are native endian; the targeted architectures are all
  little endian. Decoder timestamps precede user filters and playback speed
  filters. They are **not** inferred from the moment of polling or inference.
- The queue has 64 slots of at most 64 KiB: approximately 4 MiB, allocated at
  enable time. Capture performs bounded copies with no allocation, locks,
  inference, resampling, I/O or waiting. Each poll transfers at most 256 KiB.
- Overflow, rejected frames and filter resets invalidate continuity (`epoch`).
  The consumer must discard its analysis window on an epoch change, timestamp
  gap, format change, or playback generation change. `epoch` alone does not
  identify a player/media; it can restart with a new chain.
- The consumer must downmix/resample off the playback thread to mono float32 at
  16 kHz and keep a separate ring of at most 30 seconds. This part is pending.
- Disabling frees/erases the raw queue. Teardown disables it. Source audio is
  forwarded unmodified to mpv's existing filter chain.

The feasibility tests must still demonstrate sample contents, timestamp mapping,
seek/track/speed/buffering behavior and audible-output preservation on both
platforms. A successful patch application is not that evidence.

## Reproduction

From the Plezy fork:

```sh
python3 scripts/livesync/prepare_native.py whisper --dest build/livesync/whisper-source
python3 scripts/livesync/prepare_native.py models --dest build/livesync/models
python3 scripts/livesync/prepare_native.py mpv-build --dest build/livesync/mpv-source
```

The Apple build uses the pinned upstream driver's `make build use-prebuilt
libs=libmpv platform=macos` from the prepared mpv-build directory. This rebuilds
mpv and reuses the selected dependency install trees. Windows uses the upstream
Linux cross-build driver (`bash platforms/windows/build.sh x86_64`), including
its pinned LLVM/MinGW bootstrap, which can take hours on a cold runner.

The whisper smoke workflow performs actual inference against the upstream JFK
fixture using pinned `base.en` and `base.en-q5_1`. It proves neither the mpv tap
nor temporal accuracy against SRT. Fixture outputs are permitted evidence; no
production dialogue should be saved by default.

## Building the macOS fork application

macOS now selects a generated local `macos/LiveSyncMPV` Swift package. Its
manifest and small wrapper sources come from the exact upstream native commit.
Only the `Libmpv` binary target changes to the locally built, patched
XCFramework; all other dependency URLs, checksums and linker settings are kept.
The package is ignored by Git and must be staged before a macOS app build:

```sh
python3 scripts/livesync/stage_macos_package.py \
  --source build/livesync/mpv-source \
  --archive build/livesync/mpv-source/dist/release/Libmpv.xcframework.zip \
  --sha256 <SHA256-of-the-reviewed-build-artifact>
flutter build macos --debug --no-pub
```

The helper rejects a changed upstream lock, wrong source revision, archive hash
mismatch and a stock binary without the PCM property. A provenance JSON is
written beside the generated package. Do not substitute an arbitrary downloaded
archive. The `LiveSync macOS app and native contracts` workflow builds and stages
its own artifact from the same checkout before building and testing the app.
The app-hosted XCTest exercises activation, timestamped decoded PCM and disabling
in the actual app-linked library, with generated audio and paced null output.
This is not a test of audible playback, video rendering or the complete feature.

The original signed-release workflow and upstream `set_native_revision.sh` have
not yet been adapted for the fork's distribution/native update process. Use the
LiveSync test workflow; do not run the original release workflow. A native pin
update must rebuild the patched artifact, regenerate the local package and
revalidate its provenance. iOS/tvOS still use their original remote packages.


## Visual renderer feasibility harness

With an existing FFmpeg executable (fixture generation only):

```sh
python3 scripts/livesync/create_renderer_fixture.py --output build/livesync/renderer-fixture
flutter build macos --debug --no-pub -t tool/livesync_player_probe.dart \
  --dart-define=LIVESYNC_FIXTURE_DIR="$PWD/build/livesync/renderer-fixture"
```

Launch the resulting test app, compare the first cue, positive delay, negative
delay, and Restore manual. Capture on/off must leave the manual delay intact.
The test uses Plezy's real `Player`/`Video` and native subtitle renderer, with
locally generated media and a known SRT. It is explicitly a feasibility screen,
not the product's LiveSync UI. Rebuild with `-t lib/main.dart` afterwards to
restore the ordinary application entrypoint. Never distribute the harness as
an implementation of automatic synchronization.


The test dylib linker reads the actual Meson dependency metadata, mpv's generated
pkg-config framework flags and the selected Swift runtime paths. It does not
require a CLI executable target or reconfigure the upstream build. `--arch
x86_64` permits testing the Intel slice under an existing Rosetta installation;
that result does not validate physical Intel hardware, its GPU, or a full Intel
application build.

## Windows application linkage

Windows x64 requires the generated `windows/LiveSyncMPV` package. On an
authenticated machine, stage a successful `livesync-mpv-build.yml` dispatch from
this fork, then use the unchanged upstream Flutter DComp engine installer:

```sh
python scripts/livesync/stage_windows_package.py --run-id <completed-native-run>
flutter pub get --enforce-lockfile --no-example
flutter precache --windows
```

```powershell
./windows/tool/install-patched-engine.ps1
flutter build windows --debug --no-pub
```

Staging checks the run's repository, workflow, successful status, native lock
and PCM patch against the current checkout. It records the build SHA, run,
artifact identity and archive/DLL hashes, and rejects unsafe archives, a wrong
PE architecture or missing PCM properties. CMake rejects missing, changed or
stale packages instead of falling back to stock mpv. Windows ARM64 keeps the
original pinned package and has no LiveSync support yet.

The manually dispatched `livesync-windows.yml` waits for that native run,
builds the real application with the exact upstream Flutter SDK and engine,
runs the upstream native reliability contracts and probes the app-bundled DLL.
It produces test artifacts only. Python/CMake packaging tests use synthetic
PE bytes: they prove validation behavior, not Windows runtime functionality.
The original CI/release Windows jobs have not been adapted to stage the fork
package; use this dedicated workflow until upstream-maintenance wiring exists.

## Bounded PCM consumer

`pcm_buffer` and its small C bridge are portable, worker-owned native code,
independent of Flutter and whisper.cpp. They accept the v1 raw PCM packets,
convert packed/planar integer and floating samples to mono, and use a
polyphase windowed-sinc low-pass filter for conversion to float32 at 16 kHz.
The filter's center determines the output media timestamp. Startup and tail
samples without sufficient real history are withheld, not zero-padded.

The retained output ring is exactly 480,000 samples (30 seconds); snapshots
are capped at 240,000 samples (15 seconds). Input packets remain capped at
64 KiB, and accepted input rates are an explicit bounded set from 8 to 192 kHz.
Generation mismatches are rejected without affecting current audio. Epoch,
PTS, rate, format, channel count and frame-speed discontinuities clear history.
Reset/destruction erases retained dialogue. No disk, network or logging occurs
in this component. The production controller owns this worker through its
dedicated Dart isolate and the active player's weak native client.

The v1 tap omits speaker positions. Analysis therefore averages all channels
equally (one through eight), without assigning speaker roles or applying a
guessed center/LFE matrix. This is an analysis signal, not the audible downmix:
input PCM and speaker routing remain unchanged. Synthetic tests place dialogue
in every possible channel in packed and planar layouts. Real multichannel
recognition still requires end-to-end evidence; a genuine surround mix may be
less intelligible than the designated calibration fixture.

```sh
cmake -S native/live_subtitle_sync -B build/livesync/pcm-consumer -DCMAKE_BUILD_TYPE=Release
cmake --build build/livesync/pcm-consumer --config Release
ctest --test-dir build/livesync/pcm-consumer -C Release --output-on-failure
python3 scripts/livesync/probe_pcm_consumer.py \
  --library build/livesync/libmpv-probe-metadata.dylib \
  --consumer build/livesync/pcm-consumer/liblivesync_pcm_bridge.dylib \
  --output build/livesync/evidence/pcm-consumer
```

The last command reads actual decoded synthetic PCM through libmpv and the
native consumer. It validates sample values and their media times across seeks;
it does not prove production app threading, audible playback or synchronization.

`probe_inference_pipeline.py` connects the same real decoder/consumer to the
pinned whisper CLI on CPU. It accepts only the hash-pinned JFK fixture and a
hash-pinned model, feeds the bounded snapshot through stdin, and retains only
counts, timing, hashes and word-error measurements. It neither feeds whisper
the original media file nor saves captured PCM. Temporary transcript output is
deleted. Both `base.en` and its `q5_1` variant passed locally on the M4; this
single known excerpt is a feasibility smoke test, not an alignment benchmark.

```sh
python3 scripts/livesync/probe_inference_pipeline.py \
  --library build/livesync/libmpv-probe-metadata.dylib \
  --consumer build/livesync/pcm-consumer/liblivesync_pcm_bridge.dylib \
  --fixture build/livesync/source/samples/jfk.wav \
  --whisper-cli build/livesync/whisper/bin/whisper-cli \
  --model build/livesync/models/ggml-base.en.bin \
  --output build/livesync/evidence/pipeline-base.en.json
```

The Windows application workflow includes the same chain for both models,
using its actual app-bundled mpv DLL. Execution remains contingent on completion
of the native Windows build; a workflow definition is not a successful run.

## Asynchronous CPU inference worker

`InferenceWorker` owns a dedicated low-priority control thread and one reusable
whisper context. It accepts only finite 8–15 second windows, caps CPU threads at
four, and reserves a process-wide analysis slot: another worker cannot start a
concurrent inference. Input queues and completed results each hold at most one
window/result. The caller must consume a result before submitting the next job.

Generation and PCM-continuity changes cancel queued work, request abortion of
running whisper computations and discard stale results. Segment/token timestamps
are transformed from the original window's media origin and sample timebase.
Whisper token times remain experimental observations, not validated alignment
anchors or calibrated confidence probabilities. Output text/tokens are bounded;
library logs are disabled and the worker writes nothing to disk or network.

The model path must come from a held `ModelLease`. The owner must serialize
control calls and stop/join the worker from a cleanup queue before releasing
that lease. This native component is not wired to the production player yet.
Only CPU inference is implemented here; GPU selection/fallback remains pending.

```sh
cmake -S native/live_subtitle_sync -B build/livesync/inference-worker \
  -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=OFF \
  -DLIVESYNC_WHISPER_SOURCE="$PWD/build/livesync/source"
cmake --build build/livesync/inference-worker --config Release --target livesync_inference_test
python3 scripts/livesync/prepare_inference_fixture.py \
  --fixture build/livesync/source/samples/jfk.wav --output build/livesync/fixtures/jfk.f32
build/livesync/inference-worker/livesync_inference_test \
  build/livesync/models/ggml-base.en.bin build/livesync/fixtures/jfk.f32
```

This test uses an explicitly exported, hash-pinned public-domain fixture. It
checks actual CPU recognition, exact origin/speed transformation, contention,
cancellation during inference, recovery with the same model context, and model
failure. It is distinct from the active-playback probe and from app validation.
The CMake integration rejects a different whisper source revision and disables
host-specific CPU instruction flags for its baseline fallback. Older physical
CPUs and optimized CPU variants still require measured distribution testing.

`inference_bridge.h` exposes version 1 of the C ABI, with a caller-owned fixed
result buffer (64 segments, 512 tokens, 8192 UTF-8 text bytes). Consumers verify
both the ABI version and structure size before creating a worker. No C++ object
or allocation crosses the result boundary. All calls must use one serialized
background owner; destruction joins inference before releasing the model lease.

`probe_inference_worker.py` exercises this interface either with the pinned
fixture or with `--library` and `--consumer` for real active-playback PCM. The
latter submits after nine seconds of captured audio and verifies that playback
position advances before receipt of the result. It uses null audio output and
compares against a prefix of the known fixture; it does not establish temporal
alignment, audible-output preservation, or production UI responsiveness.

The portable Windows CPU worker took 17–19 seconds for the 11-second fixture
on CI (`35030407327`), exceeding the target latency. `LIVESYNC_CPU_PROFILE=
avx2-evaluation` is an explicitly opt-in comparison build for Windows x64 CI.
The workflow checks OS-aware AVX2/SSE4.2/BMI2/FMA support and the F16C CPUID bit
before loading that library. It is not a distribution profile or automatic CPU
dispatch. The default remains portable; safe runtime selection and packaging
must be implemented and validated before using an optimized build in the app.

The guarded comparison passed in run `35031841845`. On that runner's assigned
two cores/four logical processors, the same 11-second sample took 25.49/22.67 s
with portable base/q5, versus 1.69/2.15 s with AVX2. These are single trials,
excluding model load, not p95 or playback-impact results. The large improvement
supports implementing runtime CPU dispatch while retaining the portable option.
