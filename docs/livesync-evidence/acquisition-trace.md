# Preserve successful acquisition timing evidence

The startup-seek correction at `a5838cbe` recovered synchronization, but its
52.022-second calibration acquisition exceeded the chosen 45-second target.
Successful probe reports discarded the intermediate requests and matching
results, preventing a diagnosis from that run alone.

The opt-in production diagnostic observer now includes numeric inference time,
matching time, generation and continuity. The dedicated native fixture probe
timestamps these events from activation and freezes the acquisition trace in
its successful report, before subsequent manual/cache tests add new events.
The existing events include window bounds, match status, similarity and numeric
cue anchors. No audio samples, subtitle text or recognized dialogue are added.
Normal playback has no diagnostic observer or persistent trace.

The report records the existing 45-second acquisition target (plus an authored
90-second silent intro when applicable) separately from functional checks.
The timeout remains a bound on how long the diagnostic probe observes a failed
acquisition; a functional pass does not imply that the acquisition target passed.
No matching threshold, confirmation requirement, inference cadence or model is
changed by this instrumentation. A new run is required; the old 52-second result
cannot be retroactively decomposed from missing evidence.
