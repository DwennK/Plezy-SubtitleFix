# LiveSync fixture provenance

## JFK inference smoke sample

- Source bytes: `samples/jfk.wav` from whisper.cpp revision
  `927cfce34f31707e17f2bff35c349632fb9e2c3a` (MIT repository).
- SHA-256: `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
- Mono signed 16-bit PCM, 16 kHz, 176,000 samples, exactly 11 seconds.
- Speech: President John F. Kennedy, inaugural address, 20 January 1961,
  delivered as a US federal official. Public-domain federal speech.
- Primary historical source:
  https://www.archives.gov/milestone-documents/president-john-f-kennedys-inaugural-address
- The bytes are retrieved from the immutable whisper source checkout; no third
  party streaming media or private film/episode is downloaded for these tests.
- Purpose: actual inference and model-loading smoke check. This familiar excerpt
  is **not** a held-out recognition or synchronization evaluation set. Token
  timestamps are not accepted as ground truth. Word error on this sample alone
  cannot establish temporal precision or confidence calibration.

## Generated stereo waveform

`scripts/livesync/probe_pcm.py` generates 12 seconds at 48 kHz, with 317 Hz in the
left channel and 691 Hz in the right. Its formula establishes the expected PCM
value for each absolute media sample index. It tests decoder sample/PTS mapping,
channel layout, seeks, speed, pause and disable using the actual libmpv binary.
It contains no dialogue and does not test Whisper or SRT synchronization.
The fixture generator is part of this GPL-licensed fork.

## Sintel audio/SRT corpus preparation

Copyright (c) Blender Foundation | durian.blender.org. Audio and subtitles are
CC BY 3.0, as stated in the [audio notice](https://media.xiph.org/sintel/README.txt)
and [subtitle notice](https://media.xiph.org/sintel/subtitles/README.txt).
Logos/trademarks are excluded from that license. Keep these attribution notices
with every derived fixture and identify any trimming, time warp or other edit.

`corpus-sources.json` pins the stereo master, English SRT and both notices by
size/SHA-256. The audio hash also matches the distributor's published checksum.
The 68 MiB audio stays outside Git and can be obtained with:

```sh
python3 scripts/livesync/prepare_corpus.py --output build/livesync/corpus-source
```

Partitions are fixed **before matcher calibration**: 100–175 s for calibration,
200–650 s for validation (different dialogues), and 650–888 s without SRT cues.
The helper only fetches/checks bytes; it does not transcribe those partitions.
Do not tune thresholds against the held-out results. Future corpus revisions
must preserve a genuinely unused validation set if these partitions are used
for implementation debugging.

The source is real film audio, stereo 48 kHz, 888 seconds, with 26 authored cues.
Those cue boundaries are **not manually annotated speech-onset ground truth**.
Before claiming absolute temporal precision, independently annotate acoustic
anchors and record uncertainty. Known synthetic timeline transformations will
provide relative mapping expectations, separately from cue authoring lead/lag.
This prepared source does not yet validate automatic alignment or any transformed
scenario. It supplements, rather than upgrades, the JFK feasibility evidence.

## Scene edits: development regressions

`scene-edits-development.json` freezes insertion, removal and crossing-cue
fixtures using already consumed Sintel 100–175 s and Elephants Dream 14–44 s.
The full original Sintel SRT is retained; sample-domain edits define the expected
piecewise transform. These are not held-out acoustic-onset annotations.
Use `scripts/livesync/create_scene_fixture.py` with verified local source
directories, then score a completed native report with `evaluate_scene_probe.py`.
The expected timeline is never passed into matching or fitting.

[Fixture semantics and failing native baselines](../../../docs/livesync-evidence/scene-edit-fixtures.md).
Every output includes source attributions, license URLs, edit provenance and
checksums. No private episode audio or transcription is part of these files.
