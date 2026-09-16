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

Six unit checks cover sample-pair preservation, half-open cuts, offset signs,
removed cues, crossing fragments and invalid edits. Generator completion alone
proves fixture preparation, not automatic gap learning or synchronization.
