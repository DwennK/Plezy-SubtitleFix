# One bounded short-window recovery attempt

Frozen before the native experiment, after current-native scene baselines and
prediction-withdrawal trials. Only already-consumed development audio is used.

## Observation and hypothesis

In the crossing-cue trial, a 15-second window recognizes two different post-edit
cue starts with offsets near −70 and −72 seconds. The following ordinary window
recovers the latter near −70 seconds, but arrives twelve seconds later. A shorter
recent window may recover that timestamp earlier by dropping unrelated leading
audio. This is a hypothesis about window placement, not proof that DTW points
are accurate word onsets.

After a confirmed prediction contradiction, request exactly one immediate
8-second tail analysis. The previous native result must have completed; native
single-inference ownership remains unchanged. Consume the opportunity only on
successful submission. A failed match/inference cannot rearm it. A newly
confirmed region or playback-generation reset permits a later independent
recovery opportunity. VAD alone, a single cue, ordinary acquisition and a stable
mapping never trigger it. All matcher, independence, fitter, slope, uncertainty,
scene-score and acceptance thresholds stay unchanged.

## Planned evaluation

Run the same complete 105-second crossing-cue PCM fixture with current pinned
native libraries and base.en-q5_1. Record actual window bounds, inference time,
anchors, mapping, suppression requests and unchanged scene assessment. The
narrow hypothesis needs a real 8-second retry followed by a correctly confirmed
mapping earlier than the previous ordinary retry would have supplied it.
Failure or recognition variation is retained, not resolved by selecting a lucky
run. This does not establish exact boundaries, automatic gaps or full accuracy.

If the hypothesis is supported, check ordinary acquisition and negative inputs
before considering promotion. Independent validation partitions remain untouched.
The full goal still requires native controller/UI, scene boundaries, drift,
precision and performance evidence.
