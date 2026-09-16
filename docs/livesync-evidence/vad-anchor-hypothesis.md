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

### First integration result and scheduling follow-up

The frozen 4fc16a06 replay rejects the known early cue 7 and cue 10 timestamps,
but spends the shared short retry at 44.714 seconds, before the inserted scene
ends. At 81.748 seconds, cue 8 supplies a new credible anchor while cue 10 loses
its unsupported timing. The global spent flag prevents the needed retry.
Recovery regresses to 28.5 seconds; median/p95 both reach 30.210 seconds and
scene acceptance fails. The full numeric failure is retained in
[speech-support-first-4fc16a06.json](speech-support-first-4fc16a06.json).

Freeze the following scheduling correction before replay: a spent retry can be
rearmed by an accepted cue-start anchor strictly later than the end of the
window that requested the previous short retry. That anchor must be inside the
current window's upper bound. Repeated evidence from the same or overlapping
past audio cannot rearm it. This permits progress after new dialogue without
creating a repeated-analysis loop on the same PCM. Keep all VAD, matcher,
uncertainty, fitter and scene acceptance thresholds unchanged.

The short retry result itself cannot rearm an immediate retry. Its final window
end extends the covered-audio bound before subsequent ordinary results may
rearm the slot. A failed inference clears only the awaiting-result marker.

### Follow-up outcome

The cb9abb2f active-PCM replay reacquires 18.875 media seconds after the edit,
versus 28.5 seconds in the first integrated candidate. The unsupported cue-10
point is rejected; its fresh eight-second retry supplies a supported point and
two credible post-edit cues fit an offset of -70.032 seconds. This run does not
beat the pre-VAD e85fd4bd recovery observation of 17.114 seconds; window positions
also differ. Initial acquisition takes 21.533 seconds. Aligned median is 0.214
seconds, p95 is still 30.214 seconds, and no gap is learned: full scene checks
remain failed. The short result cannot request an immediate retry chain.

The frozen 4fc16a06 ordinary control acquires in 21.650 seconds with 0.209-second
p95, and its 238-second unmatched control never locks. Neither produces any
speech rejection; these are retained as 4fc16a06 controls, not reruns at cb9abb2f.
Native inference/ABI smoke passes on both desktops at 4fc16a06; desktop Dart
component CI passes at cb9abb2f. A separate build without the embedded detector
recognizes the fixture while all token support remains unknown. This exercises
the unknown fallback, not an injected operating-system allocation failure.

Numeric evidence: [integration controls](speech-support-integrated-4fc16a06.json)
and [bounded retry follow-up](speech-support-retry-cb9abb2f.json). The installed
Mentalist fix remains b18c9891. No production installation, acoustic-precision,
full-app packaging or performance-budget acceptance follows from this candidate.

### Cache compatibility

The candidate uses `bounded-affine-speech-v3` for mapping identity and envelope
validation. A valid-checksum map from `bounded-affine-titles-v2` is not reused
because its accepted cue-start evidence predates voice support. The regression
first accepts that old envelope on the previous version (test fails), then
rejects it after the version bump; cache round-trip and controller restoration
checks still pass. This changes no installed user data during development.

### Production activity-mismatch follow-up

The controller can request a recheck when mapped subtitle display activity and
audio activity strongly disagree. The old cadence returned 30 seconds before
considering its 12-second confirmation/native-failure retries. A regression
reproduces that postponement; df214247 preserves faster checks and only caps
otherwise sparse checks at 30 seconds. All 171 module tests pass with one
existing skip; focused analysis passes. No matching threshold changes.

Earlier native replays did not pass this production hint into cadence. Probe
8718dcec now applies the same tolerances and records each requested interval.
A new crossing replay exercises 74 mismatch observations, with 12-second
confirmation intervals, but fails scene acceptance: cue 8 establishes one
post-edit point while the short retry does not recover cue 10. Old context
repeating cue 8 cannot provide a second independent confirmation. Median/p95
remain 30.210335 seconds, with no recovery or gap. The generic probe's constant
-100-second check exits successfully; the unchanged separate scene oracle
correctly rejects it.

Window origins differ from the earlier cb9abb2f success by about 170 ms at the
short retry, so this failure exposes recognition fragility rather than proving
a causal cadence regression. Keep both outcomes. The next alignment work must
obtain independent post-edit timing reliably without accepting silence points
or counting one utterance twice. [Numeric receipt](activity-mismatch-8718dcec.json).
