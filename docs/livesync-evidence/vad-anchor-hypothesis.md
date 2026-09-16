# Bounded VAD evidence around real timing anchors

Frozen before inspecting VAD results. This is an experiment, not a production
algorithm or replacement for dialogue matching.

## Hypothesis

Some accepted DTW cue beginnings are seconds away from their later corrected
timestamps. A separate speech detector on the same bounded PCM window may
identify those points as non-speech, making it possible to reject unreliable
timing without relaxing matching thresholds or inferring a large jump from VAD.
First measure whether it separates the known bad cue-10 observation from its
short-window correction, and whether ordinary accepted anchors remain supported.

Use Silero v6.2.0 through the already pinned whisper.cpp revision
`927cfce34f31707e17f2bff35c349632fb9e2c3a`. Freeze the published ggml model at
repository revision `9ffd54a1e1ee413ddf265af9913beaf518d1639b`, retain its SHA-256,
and use upstream default segmentation parameters: threshold 0.5, minimum speech
250 ms, minimum silence 100 ms, padding 30 ms. CPU only, two threads. No parameter
search or threshold adjustment after seeing this replay.

## Evaluation

Replay only the exact recent windows recorded in the e85fd4bd crossing-cue and
ordinary six-channel controls. Decode the already consumed public development
fixture locally, not a private server or full episode. Record numeric intervals,
anchor membership, distance to the nearest voiced interval, elapsed process
time including model load, model/binary/input hashes and window bounds. CLI VAD
timestamps are centiseconds and must be converted to seconds before adding the
media-window origin.

The narrow hypothesis requires the known early cue-10 timestamp to lie outside
speech while its correction lies inside, without rejecting ordinary control
anchors. Failure is retained rather than fixed by moving VAD thresholds. Caption
times remain caption references, not independently annotated acoustic onsets.
No full precision, gap, native-player, audible-output or performance-budget claim
can follow from this probe. Production PCM ownership and scheduling stay intact.

Model source: https://huggingface.co/ggml-org/whisper-vad/tree/9ffd54a1e1ee413ddf265af9913beaf518d1639b
(MIT model card). The pinned source's `examples/vad-speech-segments` and public
VAD API define the units and default parameters used here.
