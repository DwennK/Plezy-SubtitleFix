# Lightweight activity monitoring

The production analysis isolate samples the latest two seconds from the existing
mono 16 kHz capture buffer every controller tick (500 ms while playing, once at
least eight seconds of PCM are available). It reuses the inference staging
allocation and erases that copy before returning. No second stream, microphone,
PCM file, model or network service is involved. Only aggregate timing crosses
back to the main isolate.

`VoiceActivityDetector` processes only new samples from overlapping snapshots.
Its 20 ms frames use energy, an 80 Hz–3.8 kHz band filter, zero crossings and a
200 ms hangover. The adaptive noise floor follows low background levels slowly.
The detector retains at most 1,500 timing/boolean frames and twelve media seconds
of history, with no stored PCM. Generation, continuity, speed or missing-sample
changes clear the history. Duration and boundaries remain in media seconds.

This is a heuristic VAD, not a proven speech/music classifier or confidence
probability. Speech-band tones can activate it; quiet dialogue can be missed.
Synthetic tests explicitly retain that limitation. It never creates an anchor,
changes an offset, validates a cached mapping, or establishes a scene gap.

## Scheduling and subtitle structure

- Keep one initial ASR analysis and a 90-second periodic fallback in quiet areas.
- A transition to possible voice permits acquisition after the existing minimum
  12-second interval. Continuous music-like activity cannot repeatedly bypass the
  normal 30-second unsuccessful-acquisition backoff.
- A recognized passage lacking enough timing anchors still gets a wider 15-second
  retry. Repeated native errors remain bounded by the earlier retry policy.
- After the first constant correction, allow up to ten confirmation requests
  at 12-second intervals to gather a longer drift baseline. Repeated successful
  corrections do not replenish that allowance. Then use 30 seconds until the
  mapping is established and 90 seconds afterwards. Quiet/mismatch policies
  still apply. Two native recovery attempts can also shorten the normal mapped
  interval instead of leaving an old correction unchecked for another 30–90 s.
- With a mapping, compare aggregate activity against the union of dialogue cue
  durations (normalization excludes sound-only cues). Large disagreement allows a
  verification after 30 seconds instead of the normal 90-second established-map
  interval. Wide thresholds account for captions starting early or ending late.
- The last reliable mapping remains governed by its own evidence and domain;
  activity disagreement alone cannot revoke it or authorize a large jump.

The cadence has a periodic fallback even without activity. These scheduling
thresholds need real-corpus and CPU-budget validation; unit tests are not that
validation. Diagnostic instrumentation is opt-in and returns only counts, timing,
and reasons for an analysis request, never dialogue or samples.

## Verification scope

Tests cover silence/rumble, deliberately accepted speech-band tone, overlapping
snapshots, media speed, bounded history, expired activity, seeks, continuity,
corrupt samples, merged subtitle intervals and activity-driven cadence including
continuous music-like input. The native probe measures the aggregate cost and
maximum wall duration of these background calls during real PCM playback.
Neither that maximum nor synthetic tests establish UI latency, CPU/GPU usage,
speech-classification accuracy, audible playback or dropped-frame budgets.

The controller also stops a capture that supplies no samples for 30 observed
seconds of active, unbuffered playback. Silence is not a failure: silent PCM
contains samples. Pauses, buffering and long polling gaps cannot consume this
deadline at once. Passthrough is rechecked during playback and is never silently
disabled. Teardown waits for the native worker before a new session can own the
capture, and removes only the automatic subtitle contribution. This watchdog
covers startup absence; it does not yet diagnose every possible stale-buffer or
unexpected-isolate-exit failure.
