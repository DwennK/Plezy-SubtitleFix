# Contradicted predictions and temporary presentation

The current-native crossing-cue baseline recognizes independent post-edit cues
with offsets near −70 and −72 seconds. Both reject the old −100 second
prediction, but cannot yet fit a replacement. The tracker previously kept
extrapolating the old mapping.

Candidate `b873ff50` withdraws that prediction. Its [actual PCM/Whisper
report](prediction-revocation-b873ff50.json) proves withdrawal between media
82.002 and 93.256 seconds, but also records a regression: the existing unknown
fallback uses zero delay, increasing p95 error from 30.210 to 70 seconds.
That candidate is not promoted. Recovery takes 28.023 media seconds after the
edit and no gap is learned; initial acquisition is 21.408 seconds.

## Presentation follow-up

A separate transient `predictionContradicted` flag now identifies this state.
It never classifies or persists a video-only gap. The controller masks subtitles
before clearing its automatic offset, then applies a newly confirmed offset
before releasing the mask. Ordinary initial acquisition and unknown seeks keep
their existing presentation. Manual delay and manual visibility remain owned by
the player. The flag applies only after the contradictory audio timestamps,
composes with audio delay, expires after the existing 120-second prediction
horizon, and clears on a new confirmed region, seek, stop or cache restore.

Ten domain cases exercise independence, valid cadence, positive/negative
changes, old context, recovery, audio delay and reset. All 170 feature plus
player delay/visibility tests and full Flutter analysis pass locally. The
renderer harness adds three actual-window states driven by injected timing
anchors: contradiction hidden, manual show still hidden, and confirmed recovery
visible. Its fixtures are synthetic; they do not claim real ASR or production
controller integration. The native ASR probe reports the requested suppression
as a domain decision, without claiming it rendered video.

## Remaining acceptance

Masking uncertain captions does not supply correctly timed captions. The
existing scene scorer and budgets remain unchanged, including samples during
recovery. No passing timing or full scene-handling claim follows from this
presentation policy. The new native Windows renderer sequence and actual-PCM
follow-up must be checked before promotion; Mentalist, exact scene boundaries,
crossing-cue splitting and audible UI remain unvalidated.

## Actual-PCM follow-up at 22d57de3

The [current-native follow-up](prediction-presentation-22d57de3.json) completes
with 21.411 s initial acquisition and 27.426 media seconds of post-edit recovery.
Eleven tracking samples request suppression from media 82.359 to 92.578 seconds;
the final sample has a confirmed mapping and no suppression request. This
validates the domain decision using actual Whisper results, not rendered video.
The unchanged scene scorer still fails: median 0.205 s, p95 70 s and zero gaps.
The numeric error includes zero-delay samples; requested masking does not erase
this failure or establish correct-caption coverage.

Dart CI for the earlier `b873ff50` passes at run `35145139413`. Its general CI
`35145226047` rejects the historical default native build (lock mismatch) before
Windows native tests. The analogous incorrectly dispatched `22d57de3` run
`35146112848` was intentionally cancelled, not counted as a timeout or success.
The corrected general dispatch `35146373296` supplies verified native build
`35097915052`. Current-source Dart `35146106705` and Windows renderer
`35146109893` subsequently passed, as did corrected general CI `35146373296`.
The [Windows renderer receipt](prediction-renderer-22d57de3-windows.json)
preserves all 16 successful states and hashes of the three inspected screenshots:
contradiction and manual-show remain masked, then confirmed recovery is visible.
Manual delay and selected subtitle track remain intact. The actual native window
captures are 1024×720 on the hosted desktop. These injected-anchor rendering
checks do not establish real-ASR controller behavior or audible playback.
