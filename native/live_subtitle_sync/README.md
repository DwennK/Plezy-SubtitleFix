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
