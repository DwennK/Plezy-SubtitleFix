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

The narrow hypothesis requires the known early cue-10 timestamp to have no voice
within the existing 350 ms anchor uncertainty, while its correction and ordinary
control anchors do. Both exact membership and distance are recorded. No anchor
is moved to a VAD onset. Failure is retained rather than fixed by moving VAD thresholds. Caption
times remain caption references, not independently annotated acoustic onsets.
No full precision, gap, native-player, audible-output or performance-budget claim
can follow from this probe. Production PCM ownership and scheduling stay intact.

Model source: https://huggingface.co/ggml-org/whisper-vad/tree/9ffd54a1e1ee413ddf265af9913beaf518d1639b
(MIT model card). The pinned source's `examples/vad-speech-segments` and public
VAD API define the units and default parameters used here.

## Measured outcome

The [complete numeric replay](vad-anchor-b32f0007.json) supports this narrow
hypothesis on the consumed development windows. The early cue-10 point is
1.960 seconds from speech; its corrected point is 0.100 seconds away. All nine
ordinary control anchors have voice within the unchanged 350 ms uncertainty.
The older noisy cue-7 point in the crossing scene is also unsupported (1.760 s).
Fifteen CPU CLI invocations take 20–33 ms each including model load on this Mac;
this is not a sustained playback benchmark or a Windows result.

The replay tool initially rejected a probability-frame tail extending beyond
the file and an FFmpeg container seek that removed 65 ms from the short window.
The final tool clips only the pinned implementation's 512-sample padded final
frame and trims decoded sample indices exactly. Five parser/bounds tests pass.
The signal is independently re-decoded from public fixtures, not an identical
saved copy of the original player's PCM. No private media or transcript is used.

## Integration constraint

Rejecting the bad cue-10 anchor alone could remove the second observation that
currently triggers prediction withdrawal and the prompt short retry. Integration
must therefore validate both precision and acquisition behavior. A recognized
passage with unsupported timing may request one bounded new analysis; it must
never grant a mapping, count repeated text twice, or cause a VAD-only jump.

The next native experiment should compute speech support on the same owned
inference window, keep text matching separate, retain support with each token
through transcript context, and reject only unsupported timing. Preserve an
explicit unknown state when speech support is unavailable. Evaluate the same
scene and ordinary/negative controls before any independent validation, while
keeping fitter, uncertainty and scene-score thresholds unchanged. Model size,
checksum, license, packaging, fallback and teardown must be covered before this
can become part of the distributed runtime. None of that integration is claimed
by this offline result.

## Candidate integration frozen before active-playback replay

The candidate embeds the verified 885,098-byte model in the inference library,
with its MIT notice included in both desktop packages. The existing background
worker loads one CPU detector and reuses it, resetting recurrent state for each
8–15 second PCM window. VAD and ASR consume the same owned samples. Cancellation
is checked before and after detection; a failed detector supplies unknown
support and leaves ASR available.

Inference ABI v2 carries explicit unknown/supported/unsupported token evidence.
The media-clock scale converts the existing 350 ms uncertainty into PCM seconds.
Dart preserves this evidence through adjacent-window context. The aligner keeps
the text, scores and matcher thresholds, rejecting only an otherwise eligible
cue beginning whose earliest token lies outside detected voice. No timestamp is
moved to a speech boundary and no VAD result authorizes a mapping or gap.

A recognized phrase rejected for that timing reason may request one immediate
8-second retry even while an older mapping remains active. The same bounded
retry slot serves confirmed timing contradictions; only a learned region or a
new playback generation rearms it. No continuous short-window loop is allowed.

Local module contracts, native worker recognition and embedding-integrity checks
precede the active-playback scene replay. They do not establish full precision,
scene coverage, independent onset accuracy, or the Windows performance budget.
