# Explicit scene-edit development fixtures

These three fixtures prepare the real scene-addition/removal acceptance work.
They are not a new held-out set: Sintel 100–175 s and Elephants Dream 14–44 s
were already consumed for development. Elephants Dream 360–540 s is untouched.
No algorithm threshold was selected from these new edit results.

The manifest freezes sources, hashes and sample-domain edits before inference:

| Case | Edit in original Sintel time | Expected media mapping |
|---|---|---|
| added-scene | Insert ED 14–44 s at 134.5 s | offset −100 before / −70 after; video-only 34.5–64.5 s |
| removed-scene | Remove Sintel 134.5–147.5 s | offset −100 before / −113 after; subtitle-only 134.5–147.5 s |
| added-scene-crossing-cue | Insert ED 14–44 s at 136.25 s | cue 8 crosses the cut; its expected display is split around the 30-second absence |

The full original Sintel SRT bytes remain unchanged. Only public source audio
is edited offline. Decoding is restricted to the listed partitions, converted
to stereo 48 kHz signed-16-bit PCM, then sliced by integer sample indices.
Production playback does not invoke this generator or open an extra stream.
Source attributions and license URLs accompany every generated fixture.

`expected-timeline.json` contains the exact edit transform and the expected cue
display fragments, including fully removed and crossing cues. This is not
manually annotated speech-onset ground truth. The oracle is consumed by a
separate evaluator after ASR completes; it is never injected into the learner.
The evaluator retains the existing 45 s initial acquisition, 250 ms median
and 750 ms p95 targets; post-edit recovery uses the same 30 s target as an
unknown seek. These targets are frozen before running the edited audio. Its result covers domain tracking only. Actual native
rendering, backward seeks and production-controller integration remain separate.

Seven unit checks cover sample-pair preservation, half-open cuts, offset signs,
removed cues, crossing fragments and invalid edits. Generator completion alone
proves fixture preparation, not automatic gap learning or synchronization.

## Native baseline at f3621f5c

All three baseline cases fail the complete domain checks. Initial acquisition
is about 21.4 s; the engine later learns two offset regions but **zero gaps**.

| Case | Recovery after edit, media seconds | Aligned median / p95 error | Evidence |
|---|---:|---:|---|
| Added scene | 29.634 | 30.210 / 30.210 s | [report](scene-added-scene-f3621f5c.json) |
| Removed scene | 11.575 | 0.220 / 12.780 s | [report](scene-removed-scene-f3621f5c.json) |
| Crossing cue | 27.965 | 30.205 / 30.205 s | [report](scene-added-scene-crossing-cue-f3621f5c.json) |

Tracking includes the transition after the first lock. It exposes continued
application of the old offset before reacquisition. The matched text after an
insertion first supplies one accurate cue, then another cue with a bad timestamp;
only a later window provides mutually consistent anchors. No thresholds are
relaxed and no missing interval is classified as learned from these results.

This uses the local c734 mpv development library, whose hashes and native inputs
are retained, and actual active PCM with base.en-q5_1. It is not a current-bundle
acceptance run. Audio is null output; no production UI or audible claim follows.
The generated MKV audio was independently decoded and compared byte-for-byte
against each edited WAV. Sources and the unused ED 360–540 s partition remain
unchanged. Next work must address automatic edit learning and boundary rendering,
not merely a final offset that happens to be correct after the scene.
