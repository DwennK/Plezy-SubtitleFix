# Timeline domain work in progress

This branch contains the bounded domain model for phase E. It is not yet wired
into the production controller or renderer and does not establish native drift
or scene-gap support. Production still applies a constant offset.

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
the last cue start. It never asserts that unobserved future playback is valid.
An insertion or refinement preserves previously learned regions and rejects
contradictory overlaps. Video-only and subtitle-only gaps are explicit objects;
the fitter never infers them from silence or a failed match. A learner must
supply independent evidence and resolve boundaries before inserting any gap.

Seventeen domain tests cover zero/positive/negative offsets, a 90-second intro,
23.976/25 drift with an outlier, insufficient span, repeated phrases, competing
editions, invalid evidence, scene insertions/deletions, half-open boundaries,
unknown intervals, retained regions on backward seeks and conflicting updates.
These use injected anchors. They do not test real speech or native rendering.

Remaining integration: observation provenance, learner/discontinuity policy,
bounded and explicitly uncertain prediction, cues crossing boundaries,
audio/manual delay composition, renderer proof, cache and held-out real audio.
