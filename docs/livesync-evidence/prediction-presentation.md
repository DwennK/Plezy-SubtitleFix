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
