# Timeline domain work in progress

The bounded domain model and learner are connected to the production controller.
The controller queries mpv's media clock every 500 ms and updates `sub-delay`
when its automatic contribution changes by at least 10 ms. This integration
still needs native drift and boundary validation; scene-gap suppression is not
implemented. Existing constant-offset native evidence predates this integration.

All times are seconds. The canonical mapping is `media = slope * subtitle +
offset`; media bounds are derived from subtitle bounds. Regions are half-open.
A positive offset delays subtitles. At a mapped media position, the automatic
mpv delay would be `media - (media - offset) / slope`, before the separately
owned manual contribution. Renderer behavior at boundaries still needs proof.

Fitting uses independent cue IDs and normalized phrases, bounded to 128 input
anchors. A constant fit needs two distinct phrases separated by three seconds.
An affine fit needs six phrases over at least 60 seconds in both timelines;
pairwise slopes use pairs separated by 30 seconds. Median slope and intercept,
a residual majority, and an improvement over the constant fit reject weak or
contradictory evidence. These are heuristics, not calibrated probabilities.

A fitted region spans only its inlier anchors, ending one microsecond beyond
the last cue start. The learner keeps predictions separate from this map. During
continuous playback it may predict at most 120 media seconds beyond the last
observed anchor; a seek, rate change or capture discontinuity revokes that
prediction. Known regions survive those events. Media/track changes and disable
clear the session map. No persistent cache is involved yet.
An insertion or refinement preserves previously learned regions and rejects
contradictory overlaps. Video-only and subtitle-only gaps are explicit objects;
the fitter never infers them from silence or a failed match. A learner must
supply independent evidence and resolve boundaries before inserting any gap.

Seventeen domain tests cover zero/positive/negative offsets, a 90-second intro,
23.976/25 drift with an outlier, insufficient span, repeated phrases, competing
editions, invalid evidence, scene insertions/deletions, half-open boundaries,
unknown intervals, retained regions on backward seeks and conflicting updates.
These use injected anchors. They do not test real speech or native rendering.

Six learner tests additionally cover expiring predictions, known/unknown seeks,
incremental cadence fitting, confirmed offset jumps with unknown boundaries,
contradictory overlapping editions and session reset. Individually confirmed
clusters are retained for fitting because drift can exceed the constant-fit
tolerance before the six-anchor/60-second slope requirement is met. A refinement
must explain both old and new observations within 800 ms, without dropping old
domains. At most 128 continuous observations, 24 pending observations and 128
segments are retained; unbounded history is never accumulated.

The controller checks every 30 seconds after first acquisition until a segment
contains six anchors spanning 60 seconds, then every 90 seconds. These intervals
and the 120-second prediction bound remain heuristics requiring real validation.
During acquisition, a quiet section backs off to 30 seconds, but a recognized
passage without enough timing evidence retries after 12 seconds with a 15-second
window. The first two consecutive rejected native analyses also allow a prompt
retry; further consecutive failures back off. This responds to the Windows
intro failure without weakening text or temporal confirmation requirements.
The Windows application probe now checks native delay after a paused seek to an
unknown region and back into the learned domain, including the manual delay.
Its success must be checked in CI before claiming the native behavior is proven.

Audio delay is composed in the audio source timeline: at video time `M` and
manual audio delay `d`, lookup uses `M - d`, and the final automatic subtitle
delay is `M - subtitleFor(M - d)`. The separately owned manual subtitle delay
is added by the player. This avoids a sign/scale error when the slope differs
from one. A seventh learner test covers positive/negative audio delays, affine
timing and shifted domain boundaries. The application probe also checks both
audio-delay signs, then confirms that disabling LiveSync preserves the user's
audio and subtitle controls. Audible synchronization still needs native proof.

Remaining work: explicit gap learning and subtitle suppression, cues crossing
boundaries, audio-delay native validation, smoothing, renderer proof, persistent cache,
performance and independent real-audio drift validation. A changed offset alone
does not locate a cut: the interval between incompatible regions stays unknown.
