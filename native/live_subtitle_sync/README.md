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
